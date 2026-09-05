-- ============================================================
-- BL-01C-DB-01: BOOKING-SCOPED MESSAGING STATUS BOUNDARY
-- ============================================================
--
-- SCOPE
-- -----
-- Enforces the messaging send boundary locked in docs/DECISIONS.md
-- ("Clarification -- Messaging Send Boundary", 2026-09-05), which until
-- now was recorded as LOCKED, NOT YET IMPLEMENTED.
--
-- This migration:
--   1. narrows direct table privileges on public.messages
--   2. DROPs and recreates the participant SELECT policy TO authenticated
--   3. DROPs and recreates the participant INSERT policy TO authenticated,
--      adding the missing Booking-status and content predicates
--
-- It creates no table, no column, no index, no constraint and no
-- trigger, so the locked 11-table ERD (D-001) is untouched. Two
-- Messaging policies are replaced by two Messaging policies, so the
-- public policy count is unchanged at 25.
--
-- WHY RLS AND NOT AN RPC
-- ----------------------
-- Every other trusted write in this project (N9 acceptance, N10
-- verification, N12 notifications, BL-01A lifecycle) became a
-- SECURITY DEFINER RPC because the pre-existing policy was structurally
-- wrong: it authorised the wrong actor, or it applied no actor check at
-- all. Messaging is not in that category. The existing policies already
-- establish the two hard facts a send needs -- that the caller is a
-- participant of this Booking, and that sender_id cannot be spoofed --
-- and they establish them correctly. What is missing is one conjunct:
-- the Booking status.
--
-- A send RPC would therefore add a SECURITY DEFINER surface, an EXECUTE
-- grant and a hand-written authorization body purely to re-derive
-- membership that RLS already derives, and it would move a check the
-- planner enforces on every row into procedural code that must be kept
-- in step by hand. The narrower change is to complete the predicate
-- where it already lives. Direct INSERT under a complete WITH CHECK is
-- the smaller privilege boundary here, not the larger one.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
-- No UPDATE and no DELETE policy is created: after this migration a
-- message is append-only from the application's point of view, with no
-- edit, delete or recall path. `messages.is_read` keeps its column, its
-- `false` default and NO maintenance path -- read receipts, a mark-read
-- RPC and message notification fan-out all remain deferred, as does
-- Realtime. No publication is altered. No Booking, Job, notification or
-- ratings policy is touched, and no BL-01A, N9, N11 or N12 function is
-- redefined.
--
-- THE FINDING BEING CLOSED
-- ------------------------
-- The pre-BL-01C policies, from 20260810153826_remote_schema.sql, were
-- participant-scoped and spoof-proof but carried NO status predicate at
-- all:
--
--   CREATE POLICY "Users can send messages in their bookings"
--     ON public.messages FOR INSERT
--     WITH CHECK ((auth.uid() = sender_id) AND (auth.uid() IN (
--       SELECT bookings.worker_id FROM bookings
--        WHERE bookings.id = messages.booking_id
--       UNION
--       SELECT bookings.client_id FROM bookings
--        WHERE bookings.id = messages.booking_id)));
--
-- A participant could therefore keep writing into a Booking that had
-- been `completed`, `cancelled` or recorded `no_show` -- a cancelled
-- Booking's chat stayed open indefinitely to both sides. `pending` was
-- equally open, which matters less only because the Worker-choice flow
-- (D-003) never leaves a Booking in `pending`.
--
-- Neither policy carried a TO clause, so both applied to role `public`
-- -- unlike the rest of the schema, which targets `authenticated`. They
-- failed closed for `anon` only because `auth.uid()` is NULL there,
-- i.e. by accident of the predicate rather than by grant or by role
-- targeting.
--
-- Separately, public.messages still carried the unnarrowed Supabase
-- default ACL: anon and authenticated both held arwdDxtm --
-- SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER plus MAINTAIN.
-- That is exactly the pre-N12 condition N12 closed for
-- public.notifications. It was not exploitable on its own -- anon has no
-- policy and fails on a NULL auth.uid(), and authenticated UPDATE and
-- DELETE had no policy to permit them -- but it left the table one
-- mistaken permissive policy away from an edit or delete path.
--


-- ---------- 1. DIRECT TABLE PRIVILEGES ----------
--
-- An application client needs exactly two things from this table
-- directly: SELECT of its Bookings' history, and INSERT of its own
-- messages. Everything else is removed at the GRANT layer rather than
-- left standing behind the mere absence of a policy, so a future policy
-- mistake cannot silently open an edit or delete path (GAP-004
-- discipline: do not rely solely on RLS to hide an unnecessary
-- privilege).
--
-- REVOKE ALL rather than an enumerated list, so the end state does not
-- depend on which privilege letters this server version happens to
-- support: PostgreSQL 17 added MAINTAIN ('m'), which IS present in the
-- current ACL and which an enumerated REVOKE written against an older
-- list would have left behind.
--
-- anon loses all direct access and is granted nothing back.
--
-- service_role is deliberately NOT altered: Supabase operational
-- behaviour depends on it, and a broad service_role change is out of
-- scope for this piece. The table owner (postgres) holds its own
-- explicit ACL entry, which REVOKE ... FROM anon/authenticated does not
-- touch, so owner maintenance capability is preserved.

REVOKE ALL ON TABLE public.messages FROM anon;

REVOKE ALL ON TABLE public.messages FROM authenticated;

-- Re-granted explicitly so the intended end state is stated rather than
-- inherited. SELECT and INSERT are the only direct client privileges
-- that remain; UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER and
-- MAINTAIN are all gone.
GRANT SELECT, INSERT ON TABLE public.messages TO authenticated;


-- ---------- 2. PARTICIPANT SELECT, STATUS-INDEPENDENT ----------
--
-- Recreated for two reasons only: to target `authenticated` instead of
-- `public`, and to express the membership test as one EXISTS lookup
-- rather than an IN over a two-branch UNION. The authorization decision
-- is unchanged.
--
-- NO STATUS PREDICATE IS ADDED HERE, AND THAT IS THE CONTRACT.
-- docs/DECISIONS.md locks that message history remains readable after a
-- terminal status. A participant can read their chat in `confirmed`,
-- `completed`, `cancelled` and `no_show` alike; only sending stops.
-- Adding a status filter to SELECT would delete a Booking's history
-- from both participants' view the moment it ended, which is the
-- opposite of what is locked.
--
-- The `bookings` subquery is itself evaluated under the caller's RLS,
-- and public.bookings SELECT is already participant-only, so membership
-- is enforced twice over. The explicit worker_id/client_id test is
-- still written out rather than left implicit: this policy must remain
-- correct on its own terms if the Booking policy is ever widened.

DROP POLICY "Users can view messages in their bookings" ON public.messages;

CREATE POLICY "Users can view messages in their bookings"
  ON public.messages
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.bookings b
      WHERE b.id = messages.booking_id
        AND (b.worker_id = auth.uid() OR b.client_id = auth.uid())
    )
  );

COMMENT ON POLICY "Users can view messages in their bookings" ON public.messages IS
  'BL-01C: participant-only read of a Booking''s message history. '
  'Deliberately carries NO Booking-status predicate -- history stays '
  'readable in confirmed, completed, cancelled and no_show, per the '
  'locked messaging boundary in docs/DECISIONS.md. A non-participant '
  'sees zero rows rather than an error.';


-- ---------- 3. PARTICIPANT INSERT, CONFIRMED ONLY ----------
--
-- The authoritative send boundary. All five conjuncts are enforced
-- here, server-side, and none of them is delegated to the client:
--
--   auth.uid() = sender_id      -- no sender spoofing; also makes an
--                                  anon send impossible, since sender_id
--                                  is NOT NULL and auth.uid() is NULL
--   participant of THIS Booking -- worker_id or client_id, exactly
--   b.status = 'confirmed'      -- the conjunct BL-01C exists to add
--   btrim(content) <> ''        -- no empty or whitespace-only message
--   length(content) <= 2000     -- locked maximum, in characters
--
-- The membership and status tests share ONE lookup of the Booking row,
-- so the status can never be read from a different row than the one
-- membership was proven against.
--
-- The 2000-character maximum is enforced in the policy and NOT as a
-- CHECK constraint, on purpose: a constraint would be a schema change
-- on a locked table, and the limit is an application-authorization rule
-- rather than a data-integrity invariant. length() counts characters,
-- not bytes, so the limit means the same thing for Taglish text
-- containing multi-byte characters as it does for ASCII.
--
-- Over-length content is REJECTED, never silently truncated: a
-- truncated message would misrepresent what the sender wrote.

DROP POLICY "Users can send messages in their bookings" ON public.messages;

CREATE POLICY "Users can send messages in their bookings"
  ON public.messages
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() = sender_id
    AND btrim(content) <> ''
    AND length(content) <= 2000
    AND EXISTS (
      SELECT 1
      FROM public.bookings b
      WHERE b.id = messages.booking_id
        AND b.status = 'confirmed'
        AND (b.worker_id = auth.uid() OR b.client_id = auth.uid())
    )
  );

COMMENT ON POLICY "Users can send messages in their bookings" ON public.messages IS
  'BL-01C: a message may be inserted only by an authenticated caller '
  'who is exactly this Booking''s worker_id or client_id, only while '
  'that Booking is confirmed, only as themselves (auth.uid() = '
  'sender_id), and only with non-blank content of at most 2000 '
  'characters. Membership and status are decided from ONE lookup of the '
  'Booking row. Sending stops at every terminal status while reading '
  'continues; pending is likewise not sendable. There is no UPDATE and '
  'no DELETE policy, so messages are append-only.';
