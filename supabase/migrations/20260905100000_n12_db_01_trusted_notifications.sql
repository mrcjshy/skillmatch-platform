-- ============================================================
-- N12-DB-01: TRUSTED NOTIFICATION WRITE BOUNDARY
-- ============================================================
--
-- SCOPE
-- -----
-- Closes the notification spoofing surface and gives the two
-- authoritative mutation paths that already exist (N9 acceptance, N10
-- verification) atomic, trusted notification emission.
--
-- This migration:
--   1. adds ONE value to notifications_type_check ('worker_verified')
--   2. narrows direct table privileges on public.notifications
--   3. DROPS the spoofable INSERT policy
--   4. DROPS the over-broad UPDATE policy
--   5. adds private.emit_notification()      -- internal writer
--   6. adds public.mark_my_notification_read() -- narrow recipient RPC
--   7. CREATE OR REPLACEs public.accept_job_opportunity() (N9)
--   8. CREATE OR REPLACEs public.verify_worker()           (N10)
--
-- It creates no table, no column, no index and no trigger, so the
-- locked 11-table ERD (D-001) is untouched. The recipient-only SELECT
-- policy is left byte-for-byte unchanged and is NOT widened.
--
-- THE FINDING BEING CLOSED
-- ------------------------
-- The pre-N12 INSERT policy was:
--
--   CREATE POLICY "System can insert notifications" ON public.notifications
--     FOR INSERT TO authenticated WITH CHECK (true);
--
-- Despite its name nothing about it was system-only. WITH CHECK (true)
-- let ANY authenticated account insert a notification for ANY user_id,
-- with any allowed type and arbitrary message text. It was reachable in
-- practice, not merely in theory: the N11 Booking list RPCs project
-- client_user_id / worker_user_id, so a participant already holds their
-- counterparty's id and could write a forged 'booking_confirmed' or
-- 'account_suspended' into that person's inbox, indistinguishable from
-- a genuine system message.
--
-- The UPDATE policy was named "Users can mark their own notifications
-- as read" but was column-unrestricted: a recipient could rewrite the
-- type and message of their own rows. (It could NOT reassign user_id --
-- with no WITH CHECK expression PostgreSQL reuses USING for the new
-- row -- so that part was already sound.) Mark-as-read now has its own
-- narrow RPC and the broad path is removed.
--
-- WHY DROPPING THE INSERT POLICY DOES NOT BREAK THE WRITERS
-- ---------------------------------------------------------
-- public.notifications is owned by postgres and has
-- relforcerowsecurity = false, so a postgres-owned SECURITY DEFINER
-- function runs with current_user = postgres, is the table owner, and
-- is not subject to RLS on it at all. The trusted writers therefore
-- keep working with NO insert policy present -- which is precisely the
-- point: after this migration the ONLY way a notification row can be
-- created is from inside a reviewed, postgres-owned server-side
-- function. This is the same mechanism N10 documents for its write to
-- public.worker_profiles, and the same reason N11's read RPCs can see
-- public.users rows that the caller's own policy hides.
--
-- WHY THE HELPER IS SECURITY INVOKER
-- ----------------------------------
-- private.emit_notification() is deliberately SECURITY INVOKER, not
-- SECURITY DEFINER. Called from N9/N10 -- postgres-owned SECURITY
-- DEFINER functions -- it inherits current_user = postgres and so
-- performs the owner-bypass insert described above. It therefore does
-- not need SECURITY DEFINER to work.
--
-- Making it SECURITY DEFINER would create a standing escalation
-- surface: a single mistaken future GRANT would hand an ordinary
-- account the ability to forge notifications for anyone -- exactly the
-- hole this migration exists to close. As SECURITY INVOKER the same
-- mistaken grant is harmless: an ordinary caller would execute it as
-- themselves, RLS would apply, and with no INSERT policy present the
-- insert would simply fail. The fail-safe direction is the correct one
-- for a function whose entire purpose is to be unreachable by clients.
--
-- EXECUTE is still revoked role-by-role below regardless, because
-- schema public/private grants are not the only path and defence in
-- depth is cheap (docs/SECURITY.md GAP-004).
--
-- WHAT IS DELIBERATELY NOT DONE HERE
-- ----------------------------------
--   * No Worker-opportunity fan-out. N8 matching is computed-on-read
--     with no match storage; materialising a notification per eligible
--     Worker at job-post time would require recomputing eligibility at
--     write time and would leave stale rows behind every first-wins
--     acceptance. Workers continue to discover Jobs through the
--     Opportunities screen. This is intentional, not an omission.
--   * No Realtime. public.notifications is not added to any
--     publication. The UI uses screen-entry load and pull-to-refresh,
--     matching N8-UI/N10-UI/N11-UI.
--   * No change to is_read nullability. The column stays nullable with
--     DEFAULT false; readers must treat NULL as unread using
--     `is_read IS DISTINCT FROM true`, never `is_read = false`.
--   * No new column (no title, no related-entity id, no read_at), no
--     index, no uniqueness constraint.
--   * Ratings, Booking lifecycle, Messaging and Payment surfaces are
--     untouched, including the open Ratings INSERT gap.
-- ============================================================


-- ---------- 1. TYPE DOMAIN ----------
--
-- Adds exactly one value. Every pre-existing value is preserved
-- verbatim and none is renamed or removed. The CHECK-constraint model
-- is kept rather than migrating to a PostgreSQL enum, because a CHECK
-- is what the schema already uses and an enum would be a wider,
-- harder-to-reverse change than this piece needs.
--
-- 'worker_verified' exists because N10's event has no representable
-- type today. 'account_suspended' is semantically the OPPOSITE event
-- and must never be reused to mean verification.

ALTER TABLE public.notifications
  DROP CONSTRAINT notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check
  CHECK (
    (type)::text = ANY (
      ARRAY[
        'booking_request'::character varying,
        'booking_confirmed'::character varying,
        'booking_cancelled'::character varying,
        'booking_completed'::character varying,
        'no_show_strike'::character varying,
        'account_suspended'::character varying,
        'payment_received'::character varying,
        'worker_verified'::character varying
      ]::text[]
    )
  );


-- ---------- 2. DIRECT TABLE PRIVILEGES ----------
--
-- An application client needs exactly one thing from this table
-- directly: SELECT of its own rows. Everything else is removed at the
-- GRANT layer rather than left standing behind RLS, so a future policy
-- mistake cannot silently re-open a write path (GAP-004 discipline: do
-- not rely solely on RLS to hide an unnecessary privilege).
--
-- anon loses all direct access. It previously held GRANT ALL and was
-- blocked only by having no policy -- one permissive anon policy away
-- from full table access.
--
-- service_role is deliberately NOT altered: Supabase operational
-- behaviour depends on it, and a broad service_role change is out of
-- scope for this piece.

REVOKE ALL ON TABLE public.notifications FROM anon;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.notifications FROM authenticated;

-- Re-asserted so the intended end state is explicit rather than
-- inherited; SELECT is the only direct client privilege that remains.
GRANT SELECT ON TABLE public.notifications TO authenticated;


-- ---------- 3. REMOVE THE SPOOFABLE INSERT POLICY ----------
--
-- Dropped and NOT replaced. There is deliberately no authenticated
-- INSERT policy after this migration: trusted creation happens only
-- inside postgres-owned server-side functions, which bypass RLS as
-- owner. A direct client INSERT now fails before any row exists.

DROP POLICY "System can insert notifications" ON public.notifications;


-- ---------- 4. REMOVE THE BROAD UPDATE POLICY ----------
--
-- Dropped and NOT replaced. Mark-as-read moves to
-- public.mark_my_notification_read(), which can change exactly one
-- column. A direct client UPDATE of type, message, user_id or is_read
-- now fails.

DROP POLICY "Users can mark their own notifications as read" ON public.notifications;


-- The recipient-only SELECT policy
--   "Users can read their own notifications"  USING (user_id = auth.uid())
-- is intentionally left exactly as it is. It is correct, it is the read
-- path the UI will use directly, and no read RPC is introduced.


-- ---------- 5. INTERNAL NOTIFICATION WRITER ----------
--
-- The single place a notification row is created. Minimum parameters:
-- recipient, type, message. Nothing else is accepted, so no caller can
-- smuggle a contact detail, an auth field or a pre-set read state
-- through it. id, is_read and created_at are left to their column
-- defaults.
--
-- VOLATILE (it writes). SECURITY INVOKER by design -- see the header.
-- SET search_path = '' with every object schema-qualified, so the
-- function cannot be redirected by a caller's search_path.

CREATE OR REPLACE FUNCTION private.emit_notification(
  p_user_id uuid,
  p_type    text,
  p_message text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- No exception handler, on purpose. A failure here MUST propagate to
  -- the calling authoritative mutation so the whole transaction aborts.
  -- Swallowing it would recreate exactly the split-brain this piece
  -- exists to prevent: a committed Booking or verification whose
  -- notification silently never happened.
  INSERT INTO public.notifications (user_id, type, message)
  VALUES (p_user_id, p_type, p_message);
END;
$$;


COMMENT ON FUNCTION private.emit_notification(uuid, text, text) IS
  'N12-DB-01: the ONLY notification writer. Internal to the database: '
  'EXECUTE is revoked from PUBLIC, anon, authenticated and '
  'service_role, and it is intended to be called only from reviewed '
  'postgres-owned SECURITY DEFINER functions (N9 acceptance, N10 '
  'verification), which supply current_user = postgres and therefore '
  'bypass RLS as table owner. Deliberately SECURITY INVOKER: it does '
  'not need definer rights to work in that context, and as invoker a '
  'mistaken future GRANT stays fail-safe -- an ordinary caller would '
  'run it as themselves, RLS would apply, and with no INSERT policy '
  'present the write would fail rather than forge a notification. '
  'Accepts only recipient, type and message; never contact data.';


-- Role-by-role revocation: schema private grants EXECUTE on new
-- functions to roles by name, so REVOKE ... FROM PUBLIC alone would
-- leave them in place (docs/SECURITY.md GAP-004). No role is granted
-- EXECUTE afterwards -- that omission is the point. The owner
-- (postgres) retains its own rights and needs no grant.

REVOKE ALL ON FUNCTION private.emit_notification(uuid, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION private.emit_notification(uuid, text, text) FROM anon;

REVOKE ALL ON FUNCTION private.emit_notification(uuid, text, text) FROM authenticated;

REVOKE ALL ON FUNCTION private.emit_notification(uuid, text, text) FROM service_role;


-- ---------- 6. RECIPIENT MARK-AS-READ RPC ----------
--
-- Replaces the dropped UPDATE policy with the narrowest possible
-- mutation: is_read = true, on one row, owned by the caller.
--
-- SECURITY DEFINER is required here (unlike the writer above): the
-- caller is an ordinary authenticated account with no UPDATE privilege
-- or policy on the table, so the function must supply the write right
-- itself. That is safe because the row is selected by
-- `user_id = auth.uid()` -- ownership comes from the session, never
-- from a parameter -- and because only one column can move.
--
-- What it cannot do, by construction: change type, message or
-- user_id; mark another user's notification; or mark anything unread.
--
-- FOREIGN-EXISTENCE LEAK: an id the caller does not own and an id that
-- does not exist both yield ZERO ROWS and no error, so the RPC cannot
-- be used to probe which notification ids are real.
--
-- IDEMPOTENT: re-marking an already-read owned notification updates
-- nothing meaningful and still returns the row, so a UI retry is safe.

CREATE OR REPLACE FUNCTION public.mark_my_notification_read(p_notification_id uuid)
RETURNS TABLE (
  notification_id uuid,
  is_read         boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  -- Signed-out callers are rejected explicitly rather than silently
  -- receiving "no such notification". anon never reaches this line --
  -- it is denied at the EXECUTE ACL layer below -- so this is defence
  -- in depth for an authenticated session with no uid.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to update notifications'
      USING ERRCODE = '42501';
  END IF;

  -- Exactly one column moves. The ownership predicate is part of the
  -- UPDATE itself, so a non-owned id simply matches no row.
  UPDATE public.notifications AS n
  SET is_read = true
  WHERE n.id = p_notification_id
    AND n.user_id = v_caller;

  -- Read back from the persisted row, so the caller receives observed
  -- state rather than an echoed constant. Zero rows means "not yours
  -- or nonexistent" -- deliberately indistinguishable.
  RETURN QUERY
  SELECT n.id, n.is_read
  FROM public.notifications AS n
  WHERE n.id = p_notification_id
    AND n.user_id = v_caller;
END;
$$;


COMMENT ON FUNCTION public.mark_my_notification_read(uuid) IS
  'N12-DB-01: marks ONE notification owned by the calling user as '
  'read. Ownership is derived from auth.uid(), never from a parameter, '
  'so no caller can mark another user''s notification. Sets is_read = '
  'true and nothing else: type, message and user_id cannot be changed '
  'and there is no mark-unread. An id that is not owned and an id that '
  'does not exist both return zero rows with no error, so the function '
  'is not an existence oracle. Idempotent -- re-marking an '
  'already-read owned notification is safe and still returns the row. '
  'SECURITY DEFINER because after N12 authenticated holds no UPDATE '
  'privilege or policy on public.notifications.';


REVOKE ALL ON FUNCTION public.mark_my_notification_read(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.mark_my_notification_read(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.mark_my_notification_read(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.mark_my_notification_read(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.mark_my_notification_read(uuid) TO authenticated;


-- ---------- 7. N9: ATOMIC ACCEPTANCE NOTIFICATIONS ----------
--
-- CREATE OR REPLACE, preserving the N9 contract exactly: same
-- argument, same four return columns, same 42501 / SM409 / SM403 codes
-- and messages, same authorization gate, same FOR UPDATE lock ordering,
-- same authoritative eligibility re-check, same Booking write, same
-- Job transition, same VOLATILE / SECURITY DEFINER / search_path, same
-- ACL (re-asserted below).
--
-- THE ONLY CHANGES:
--   * step 2's already-locked SELECT also reads jp.title, so no extra
--     query and no second read of a row that could have moved
--   * step 5b emits two notifications after the authoritative writes
--
-- ATOMICITY: the emissions run inside this function's single
-- transaction, after the Booking INSERT and the Job UPDATE, with no
-- exception handler anywhere around them. If either notification write
-- fails the whole statement aborts and the acceptance rolls back --
-- Booking, Job transition and both notifications commit together or
-- not at all.
--
-- DUPLICATES: no new uniqueness constraint is added, and none is
-- needed. The existing first-winner logic already guarantees at most
-- one successful acceptance per Job -- a loser raises SM409 at step 3
-- before reaching any write -- so a second attempt produces zero
-- additional Bookings and zero additional notifications.
--
-- PRIVACY: the messages carry the Job title and nothing else. No
-- phone, no email, no Worker name, no Client name. This matters beyond
-- general tidiness: a notification is immutable frozen text, while
-- N11 releases counterparty contact under a LIVE status rule
-- (confirmed/completed only). Embedding contact here would keep
-- displaying it after a Booking later became cancelled, silently
-- defeating that contract.

CREATE OR REPLACE FUNCTION public.accept_job_opportunity(p_job_id uuid)
RETURNS TABLE (
  booking_id     uuid,
  job_id         uuid,
  booking_status text,
  job_status     text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_job_status text;
  v_client_id  uuid;
  v_job_title  text;
  v_booking_id uuid;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (account level)
  --
  -- private.is_active_worker() answers "may this account use the
  -- acceptance API at all?" -- role = 'worker' AND is_active. Every
  -- denial (signed out, Client, Administrator, suspended Worker) raises
  -- the SAME error, so a rejected caller cannot tell which predicate
  -- failed and learns nothing about any Job.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized to accept opportunities'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. LOCK THE TARGET JOB -- BEFORE any eligibility work
  --
  -- The Job row is the contended resource: one Job, therefore one
  -- winner. FOR UPDATE takes a row-level exclusive lock, so a second
  -- concurrent acceptance blocks here rather than racing ahead.
  --
  -- Order matters. Locking first means the status guard immediately
  -- below does all the work: under READ COMMITTED a blocked
  -- SELECT ... FOR UPDATE re-reads the NEWEST COMMITTED version of the
  -- row once the lock is granted, so the loser sees 'matched' -- the
  -- value the winner just committed -- and stops before writing
  -- anything. Evaluating eligibility first would let both callers pass
  -- and would need a second re-check anyway.
  --
  -- N12 adds jp.title to this existing projection. It is read here,
  -- under the lock, rather than by a later separate query: the title
  -- used in the notifications is then guaranteed to be the same row
  -- version the acceptance acted on.
  ----------------------------------------------------------------
  SELECT jp.status::text, jp.client_id, jp.title::text
    INTO v_job_status, v_client_id, v_job_title
  FROM public.job_postings AS jp
  WHERE jp.id = p_job_id
  FOR UPDATE;

  ----------------------------------------------------------------
  -- 3. THE JOB MUST STILL BE OPEN
  --
  -- A Job that does not exist and a Job that is no longer open produce
  -- an IDENTICAL error, on purpose: a Worker must not be able to probe
  -- which Job ids exist, nor learn the state of Jobs they were never
  -- matched to. NOT FOUND covers the nonexistent case because the
  -- SELECT ... INTO above leaves FOUND false.
  ----------------------------------------------------------------
  IF NOT FOUND OR v_job_status IS DISTINCT FROM 'open' THEN
    RAISE EXCEPTION 'this opportunity is no longer available'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. ACCEPTANCE-TIME ELIGIBILITY -- via the authoritative scorer
  --
  -- Nothing about eligibility is recomputed here. One call to
  -- private.compute_job_matches() re-establishes ALL of D-002 Stage 1
  -- at acceptance time: role = 'worker', is_active, availability =
  -- 'available', is_verified, and required-skill overlap. That
  -- satisfies the recorded D-002 requirement to re-check is_active and
  -- is_verified at acceptance, and exceeds it -- availability and skill
  -- overlap are re-checked too.
  --
  -- Membership in the scorer's result IS the eligibility answer, so
  -- there is nothing further to test. This failure is deliberately
  -- distinct from the authorization failure in step 1: the caller is a
  -- legitimate Worker, they simply no longer match this Job.
  ----------------------------------------------------------------
  PERFORM 1
  FROM private.compute_job_matches(p_job_id) AS m
  WHERE m.worker_id = v_caller;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'you are no longer eligible for this opportunity'
      USING ERRCODE = 'SM403';
  END IF;

  ----------------------------------------------------------------
  -- 5. ATOMIC WRITES
  --
  -- Both writes run inside this function's single transaction. There is
  -- deliberately NO exception handler around them: any failure must
  -- propagate and abort the whole statement, so a Booking can never
  -- survive with the Job still open, and the Job can never end up
  -- matched without its winning Booking. Swallowing an error here would
  -- destroy exactly the invariant this function exists to provide.
  --
  -- Participant ids come from trusted sources only -- worker_id from
  -- auth.uid(), client_id from the LOCKED Job row -- never from caller
  -- input. status is written explicitly as 'confirmed' rather than
  -- inheriting the column default 'pending': under D-003 the Worker's
  -- acceptance IS the confirmation, there is no further party to
  -- approve it, and D-003 releases Worker contact details to the Client
  -- only after confirmation.
  --
  -- No payment state is invented. payment_status is omitted so its
  -- existing default 'pending' applies (meaning "not yet paid");
  -- payment_method, paymongo_ref and completed_at stay NULL.
  ----------------------------------------------------------------
  INSERT INTO public.bookings (job_id, worker_id, client_id, status)
  VALUES (p_job_id, v_caller, v_client_id, 'confirmed')
  RETURNING public.bookings.id INTO v_booking_id;

  UPDATE public.job_postings AS jp
  SET status = 'matched'
  WHERE jp.id = p_job_id;

  ----------------------------------------------------------------
  -- 5b. NOTIFICATIONS (N12) -- SAME TRANSACTION
  --
  -- Emitted only after the authoritative writes above have succeeded,
  -- and inside the same transaction, so the four facts commit together
  -- or not at all:
  --
  --   Booking confirmed
  --   + Job open -> matched
  --   + Client notification
  --   + Worker notification
  --
  -- Again no exception handler: if a notification write fails the
  -- acceptance itself must roll back rather than commit half the
  -- outcome.
  --
  -- Recipients are trusted values, never caller input: the Client from
  -- the locked Job row, the Worker from auth.uid(). Both messages
  -- carry the Job title only -- no contact detail and no counterparty
  -- name.
  ----------------------------------------------------------------
  PERFORM private.emit_notification(
    v_client_id,
    'booking_confirmed',
    'Your job "' || v_job_title || '" has been accepted.'
  );

  PERFORM private.emit_notification(
    v_caller,
    'booking_confirmed',
    'Your booking for "' || v_job_title || '" is confirmed.'
  );

  ----------------------------------------------------------------
  -- 6. RETURN THE MINIMUM PROJECTION
  --
  -- Read back from the persisted rows rather than echoing the constants
  -- written above, so the caller receives observed state.
  --
  -- No Client identity or contact data, no competitor Workers, no
  -- competitor scores, no candidate count, no rank. Client contact
  -- release after a confirmed Booking belongs to the confirmed-booking
  -- read surface, not to this function.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT b.id, b.job_id, b.status::text, jp.status::text
  FROM public.bookings AS b
  JOIN public.job_postings AS jp ON jp.id = b.job_id
  WHERE b.id = v_booking_id;
END;
$$;


-- ACL re-asserted so the end state is explicit. CREATE OR REPLACE
-- preserves existing privileges, so this is idempotent and changes
-- nothing -- it simply guarantees the N9 grant set regardless of what
-- the replace inherited.

REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.accept_job_opportunity(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.accept_job_opportunity(uuid) TO authenticated;


-- ---------- 8. N10: ATOMIC VERIFICATION NOTIFICATION ----------
--
-- CREATE OR REPLACE, preserving the N10 contract exactly: same
-- argument, same three return columns, same Administrator gate, same
-- 42501 / SM409 codes and messages, same FOR UPDATE OF wp lock, same
-- two-column write, same VOLATILE / SECURITY DEFINER / search_path,
-- same ACL (re-asserted below).
--
-- THE ONLY CHANGE: one notification is emitted after the verification
-- write, in the same transaction.
--
-- ATOMICITY: verification and its notification commit together or not
-- at all. No exception handler is introduced.
--
-- REPEAT BEHAVIOUR IS UNCHANGED AND GIVES DUPLICATE PROTECTION FOR
-- FREE: an already-verified Worker still fails the step 3 guard with
-- SM409 before reaching the write, so a second verification attempt
-- creates neither a second attribution nor a second notification.
--
-- PRIVACY: the message names no Administrator, carries no email or
-- phone, and does not expose verified_by.

CREATE OR REPLACE FUNCTION public.verify_worker(p_worker_user_id uuid)
RETURNS TABLE (
  user_id     uuid,
  is_verified boolean,
  verified_by uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_profile_id  uuid;
  v_is_verified boolean;
  v_role        text;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION -- BEFORE the target is touched or even
  --    probed, so an unauthorized caller cannot use timing or error
  --    shape to discover whether an account exists.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to verify workers'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. LOCK THE TARGET PROFILE -- BEFORE evaluating its state
  --
  -- Same ordering as N9's acceptance claim, for the same reason:
  -- under READ COMMITTED a blocked SELECT ... FOR UPDATE re-reads the
  -- newest committed version once the lock is granted, so if two
  -- Administrators verify the same Worker concurrently the loser sees
  -- is_verified = true and stops. Exactly one verified_by attribution
  -- can therefore win, instead of the last writer silently
  -- overwriting the first.
  --
  -- FOR UPDATE OF wp is deliberate: only the profile row is the
  -- contended resource. Locking the joined public.users row as well
  -- would needlessly block unrelated account activity.
  ----------------------------------------------------------------
  SELECT wp.id, wp.is_verified, u.role
    INTO v_profile_id, v_is_verified, v_role
  FROM public.worker_profiles AS wp
  JOIN public.users AS u
    ON u.id = wp.user_id
  WHERE wp.user_id = p_worker_user_id
  FOR UPDATE OF wp;

  ----------------------------------------------------------------
  -- 3. THE TARGET MUST BE A WORKER AWAITING VERIFICATION
  --
  -- Four situations produce ONE indistinguishable error, on purpose:
  --
  --   a. no such account / no worker_profiles row  (NOT FOUND)
  --   b. the account exists but is not a Worker    (GAP-002 rows)
  --   c. the Worker is already verified
  --   d. a concurrent Administrator just verified it (step 2's
  --      re-read makes this collapse into c)
  --
  -- Giving (a) and (c) different answers would turn this RPC into an
  -- account-existence oracle for anyone who reaches admin, and would
  -- leak which arbitrary uuids correspond to real accounts. Callers
  -- that need to know what is pending call list_unverified_workers().
  --
  -- Already-verified is therefore NOT treated as success. Verifying
  -- is not idempotent here precisely because a silent second success
  -- would overwrite the original verified_by attribution -- and, since
  -- N12, would also emit a duplicate notification. This guard prevents
  -- both.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_role IS DISTINCT FROM 'worker'
     OR v_is_verified IS TRUE
  THEN
    RAISE EXCEPTION 'this worker is not available for verification'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 4. THE WRITE
  --
  -- Exactly two columns. rating_avg, strike_count, badge_level,
  -- availability_status and bio are never touched: verification is
  -- not a rating, a badge, a suspension change or an availability
  -- change, and the Piece E guard exists to keep those independent.
  --
  -- verified_by comes from auth.uid() -- a trusted source -- and
  -- never from caller input.
  ----------------------------------------------------------------
  UPDATE public.worker_profiles AS wp
  SET is_verified = true,
      verified_by = v_caller
  WHERE wp.id = v_profile_id;

  ----------------------------------------------------------------
  -- 4b. NOTIFICATION (N12) -- SAME TRANSACTION
  --
  -- The verified Worker is told, atomically with the verification
  -- itself. The recipient is the target account, never the caller;
  -- the Administrator receives nothing, because verification is not
  -- an event in the Administrator's own inbox.
  --
  -- Fixed text: no Administrator name, no email, no phone, and
  -- verified_by is not exposed.
  ----------------------------------------------------------------
  PERFORM private.emit_notification(
    p_worker_user_id,
    'worker_verified',
    'Your worker profile has been verified.'
  );

  ----------------------------------------------------------------
  -- 5. RETURN THE MINIMUM PROJECTION
  --
  -- Read back from the persisted row rather than echoing the
  -- constants written above, so the caller receives observed state.
  -- Exactly three fields: the account acted on and the two columns
  -- that moved. No contact detail, no profile id and no unrelated
  -- profile column -- the caller already had to be an Administrator
  -- to get here, and this is a confirmation, not a second read
  -- surface.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT wp.user_id, wp.is_verified, wp.verified_by
  FROM public.worker_profiles AS wp
  WHERE wp.id = v_profile_id;
END;
$$;


-- ACL re-asserted, idempotent, same reasoning as N9 above.

REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.verify_worker(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.verify_worker(uuid) TO authenticated;
