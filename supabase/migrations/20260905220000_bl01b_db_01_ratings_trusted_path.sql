-- ============================================================
-- BL-01B-DB-01: TRUSTED CLIENT-TO-WORKER RATING PATH
-- ============================================================
--
-- SCOPE
-- -----
-- Implements the Ratings contract locked in docs/DECISIONS.md, which
-- until now stood as LOCKED, NOT YET IMPLEMENTED.
--
-- This migration:
--   1. DROPs the permissive direct INSERT policy (not replaced)
--   2. narrows direct table privileges on public.ratings
--   3. DROPs and recreates the SELECT policy, narrowed from
--      USING (true) to rater-or-rated-user
--   4. adds public.rate_my_completed_worker() -- the SOLE Rating writer
--   5. refreshes two now-stale COMMENT metadata strings
--
-- It creates no table, column, index, constraint, trigger, enum or
-- publication, so the locked 11-table ERD (D-001) is untouched. The
-- existing UNIQUE (booking_id, rated_by) and CHECK (score BETWEEN 1
-- AND 5) are deliberately left exactly as they are and are relied upon.
--
-- Public policy count moves 25 -> 24: the Rating INSERT policy is
-- removed and NOT replaced, while the Rating SELECT policy is replaced
-- one-for-one.
--
-- WHY AN RPC HERE, WHEN BL-01C DELIBERATELY CHOSE RLS
-- ---------------------------------------------------
-- BL-01C kept direct INSERT under RLS because the pre-existing
-- messaging policies already enforced participant membership and
-- sender identity correctly; only one conjunct was missing. Ratings is
-- the opposite case on both counts.
--
-- The pre-BL-01B policy was:
--
--   CREATE POLICY "Authenticated users can insert ratings"
--     ON public.ratings FOR INSERT TO authenticated
--     WITH CHECK (rated_by = auth.uid());
--
-- That checks one thing: that you are not forging the RATER. It does
-- not check that you are a participant of the Booking, that the Booking
-- is completed, that the Booking is even yours, that rated_user is the
-- Booking's Worker, or that the direction is Client -> Worker. So any
-- authenticated account could rate any Booking, in any status, naming
-- any user as the rated party -- including themselves.
--
-- The second reason is decisive: a Rating must transactionally maintain
-- worker_profiles.rating_avg, and that column is protected by
-- trg_guard_worker_profiles_protected_columns, whose Tier 3 raises
-- 42501 on any rating_avg change by an ordinary role. Maintaining the
-- aggregate therefore REQUIRES a postgres-owned SECURITY DEFINER
-- context (the guard's Tier 1) no matter which shape is chosen. An
-- RLS + AFTER INSERT trigger design would need exactly the same
-- privilege, while additionally leaving a direct INSERT path in which
-- the caller still supplies booking_id, rated_user, score and comment
-- for RLS to re-validate. One trusted writer that accepts no identity
-- field at all is the smaller boundary, and it matches N9, N10, N12
-- and BL-01A.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
-- No Rating UPDATE or DELETE policy and no update/delete RPC: ratings
-- are immutable pre-defense, which is what makes transactional
-- aggregate maintenance sound. No rating-received notification. No
-- Worker -> Client direction. The N8 scorer is NOT rewritten and still
-- reads worker_profiles.rating_avg; N11 is NOT rewritten and still
-- computes its aggregates live from public.ratings. The protected
-- column guard trigger is not altered.
--


-- ---------- 1. REMOVE THE PERMISSIVE INSERT POLICY ----------
--
-- Dropped and NOT replaced. After this migration there is deliberately
-- no authenticated INSERT policy on public.ratings: creation happens
-- only inside the postgres-owned function below, which is the table
-- owner and is not subject to RLS. A direct client INSERT now fails at
-- the GRANT layer before RLS is even consulted.

DROP POLICY "Authenticated users can insert ratings" ON public.ratings;


-- ---------- 2. DIRECT TABLE PRIVILEGES ----------
--
-- A client needs exactly one thing from this table directly: SELECT of
-- its own rating rows, so the UI can tell whether it has already rated
-- a Booking. Everything else is removed at the GRANT layer rather than
-- left standing behind the absence of a policy (GAP-004 discipline).
--
-- REVOKE ALL rather than an enumerated list, so the end state does not
-- depend on which privilege letters this server version supports --
-- PostgreSQL 17's MAINTAIN is present in the pre-BL-01B ACL.
--
-- anon loses all direct access and is granted nothing back.
-- service_role and the postgres owner entry are deliberately untouched.

REVOKE ALL ON TABLE public.ratings FROM anon;

REVOKE ALL ON TABLE public.ratings FROM authenticated;

-- SELECT is the only direct client privilege that remains. INSERT is
-- deliberately NOT re-granted: the RPC is the sole writer.
GRANT SELECT ON TABLE public.ratings TO authenticated;


-- ---------- 3. NARROW THE READ ----------
--
-- The pre-BL-01B policy was USING (true) for every authenticated
-- caller, so any signed-in account could read every rating row in the
-- system -- including the free-text `comment`, and the rated_by /
-- rated_user pair naming both people. That is broader than anything
-- else in this schema and is narrowed here to the two parties who are
-- actually in the rating.
--
-- This does NOT change what the app displays. N11's Booking-list RPCs
-- are SECURITY DEFINER and therefore bypass RLS on this table, so the
-- released worker_rating_avg / worker_rating_count aggregates are
-- computed exactly as before. The only direct read the client performs
-- is of its OWN rows, which this policy still permits.

DROP POLICY "Anyone authenticated can read ratings" ON public.ratings;

CREATE POLICY "Participants can read their own ratings"
  ON public.ratings
  FOR SELECT
  TO authenticated
  USING (
    rated_by = auth.uid()
    OR rated_user = auth.uid()
  );

COMMENT ON POLICY "Participants can read their own ratings" ON public.ratings IS
  'BL-01B: a rating row is directly readable only by the caller who '
  'wrote it (rated_by) or the caller it is about (rated_user). '
  'Replaces the pre-BL-01B USING (true), under which every '
  'authenticated account could read every comment and every '
  'rater/rated pair. Aggregate display is unaffected: N11''s Booking '
  'list RPCs are SECURITY DEFINER and compute their averages without '
  'consulting this policy.';


-- ---------- 4. THE SOLE RATING WRITER ----------
--
-- Client -> assigned Worker only, on a completed Booking the caller
-- owns, exactly once, with the aggregate maintained in the same
-- transaction.
--
-- THE CALLER SUPPLIES NO IDENTITY. There is no rated_by, rated_user,
-- worker_id or client_id parameter to substitute: the rater is
-- auth.uid() and the rated party is read from the Booking. Identity
-- spoofing is therefore not blocked by a check, it is unrepresentable.
--
-- LOCK ORDER IS LOAD-BEARING. The worker_profiles row is locked BEFORE
-- the rating is inserted and stays locked through the recomputation and
-- the aggregate write. This is the one real race in this piece: two
-- different Clients rating the SAME Worker on two different completed
-- Bookings concurrently is a read-modify-write on rating_avg. Without
-- the lock, under READ COMMITTED both transactions can compute their
-- average before either commits, each seeing only its own new row, and
-- the second write silently discards the first rating. With the lock
-- the loser blocks, and the AVG statement it runs after acquiring the
-- lock takes a fresh snapshot that includes the committed row.
--
-- The BOOKING is deliberately NOT locked. Both BL-01A mutators require
-- status = 'confirmed', so 'completed' is terminal with no exit path --
-- the status cannot change underneath this transaction, and taking a
-- second lock would add ordering risk for no benefit.

CREATE OR REPLACE FUNCTION public.rate_my_completed_worker(
  p_booking_id uuid,
  p_score      integer,
  p_comment    text DEFAULT NULL
)
RETURNS TABLE (
  rating_id         uuid,
  booking_id        uuid,
  rated_user        uuid,
  score             integer,
  worker_rating_avg double precision
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller         uuid := auth.uid();
  v_booking_status text;
  v_booking_client uuid;
  v_booking_worker uuid;
  v_comment        text;
  v_rating_id      uuid;
  v_avg            double precision;
  v_rows           integer;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (account level)
  --
  -- Same gate as BL-01A completion: role = 'client' AND is_active.
  -- Signed out, Worker, Administrator and suspended Client all raise
  -- the SAME error and learn nothing about any Booking. A Worker
  -- attempting to rate is rejected here, before any Booking is read --
  -- which is also how the Client-only direction is enforced.
  ----------------------------------------------------------------
  IF v_caller IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to rate bookings'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. INPUT VALIDATION, BEFORE ANY BOOKING IS READ
  --
  -- Deliberately first: a malformed score or comment is a fault in the
  -- caller's own request and reveals nothing about any Booking, so it
  -- gets its own SQLSTATE rather than being collapsed into the
  -- conflict class. 22023 is invalid_parameter_value -- a standard
  -- code, not a project-invented one.
  --
  -- The schema CHECK (score BETWEEN 1 AND 5) is left in place as
  -- defence in depth; this test exists so the caller gets a clear
  -- message instead of a raw constraint violation.
  ----------------------------------------------------------------
  IF p_score IS NULL OR p_score < 1 OR p_score > 5 THEN
    RAISE EXCEPTION 'rating score must be a whole number from 1 to 5'
      USING ERRCODE = '22023';
  END IF;

  ----------------------------------------------------------------
  -- 3. COMMENT NORMALISATION
  --
  -- The trim set is spelled out rather than relying on btrim's default,
  -- which strips ONLY spaces: a comment of newlines or tabs would
  -- otherwise survive as "non-empty" and be stored as blank noise.
  -- Empty and whitespace-only both become NULL, so "no comment" has one
  -- representation in the table instead of three.
  --
  -- Length is measured on the NORMALISED value, so trailing whitespace
  -- cannot push an otherwise-valid comment over the limit. Over-length
  -- is rejected, never truncated: a truncated comment would
  -- misrepresent what the Client wrote. No schema CHECK is added --
  -- this is an application rule on a locked table, the same reasoning
  -- BL-01C applied to message length.
  ----------------------------------------------------------------
  v_comment := NULLIF(btrim(COALESCE(p_comment, ''), E' \t\n\r\f\v'), '');

  IF v_comment IS NOT NULL AND length(v_comment) > 1000 THEN
    RAISE EXCEPTION 'rating comment must be 1000 characters or less'
      USING ERRCODE = '22023';
  END IF;

  ----------------------------------------------------------------
  -- 4. RESOLVE THE BOOKING
  --
  -- Not locked: 'completed' is terminal (see the header note).
  ----------------------------------------------------------------
  SELECT b.status::text, b.client_id, b.worker_id
    INTO v_booking_status, v_booking_client, v_booking_worker
  FROM public.bookings AS b
  WHERE b.id = p_booking_id;

  ----------------------------------------------------------------
  -- 5. THE BOOKING MUST EXIST, BE OURS, BE COMPLETED, HAVE A WORKER
  --
  -- One error for all four. A Client must not be able to distinguish
  -- "no such Booking" from "somebody else's Booking" from "not
  -- completed yet", or the function becomes a Booking-existence
  -- oracle. NOT FOUND covers the nonexistent case because
  -- SELECT ... INTO leaves FOUND false.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_booking_client IS DISTINCT FROM v_caller
     OR v_booking_status IS DISTINCT FROM 'completed'
     OR v_booking_worker IS NULL
  THEN
    RAISE EXCEPTION 'this booking is not available for rating'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 6. LOCK THE WORKER PROFILE -- BEFORE THE INSERT
  --
  -- Serialises aggregate maintenance per Worker. A Booking whose
  -- Worker has no profile row is anomalous data: fail closed with the
  -- same collapsed error rather than write a rating whose aggregate
  -- has nowhere to go.
  ----------------------------------------------------------------
  PERFORM 1
  FROM public.worker_profiles AS wp
  WHERE wp.user_id = v_booking_worker
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'this booking is not available for rating'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 7. INSERT THE RATING
  --
  -- Every identity is server-derived. The duplicate case is caught
  -- narrowly and re-raised in the established conflict class, so the
  -- caller never sees 23505 or the constraint name. Only
  -- unique_violation is caught: any other integrity failure propagates
  -- and rolls the call back rather than being swallowed.
  ----------------------------------------------------------------
  BEGIN
    INSERT INTO public.ratings (booking_id, rated_by, rated_user, score, comment)
    VALUES (p_booking_id, v_caller, v_booking_worker, p_score, v_comment)
    RETURNING id INTO v_rating_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'this booking is not available for rating'
        USING ERRCODE = 'SM409';
  END;

  ----------------------------------------------------------------
  -- 8. RECOMPUTE THE AGGREGATE FROM AUTHORITATIVE ROWS
  --
  -- A full recomputation, NOT incremental math such as
  -- (old_avg * n + score) / (n + 1). Ratings are immutable, so the
  -- rows are the truth; recomputing is exact every time and self-heals
  -- if rating_avg was ever wrong, whereas incremental arithmetic
  -- compounds double precision error and can never recover. At
  -- capstone scale the cost is trivial.
  --
  -- Runs while the profile row lock from step 6 is still held.
  ----------------------------------------------------------------
  SELECT AVG(rt.score)::double precision
    INTO v_avg
  FROM public.ratings AS rt
  WHERE rt.rated_user = v_booking_worker;

  ----------------------------------------------------------------
  -- 9. WRITE THE AGGREGATE
  --
  -- Succeeds despite trg_guard_worker_profiles_protected_columns
  -- because this function is owned by postgres and runs SECURITY
  -- DEFINER, so current_user is 'postgres' and the guard returns at
  -- Tier 1. The guard is NOT weakened: an ordinary role updating
  -- rating_avg directly still reaches Tier 3 and is refused. This is
  -- the same trusted mechanism N10's verify_worker() uses for
  -- is_verified.
  --
  -- The row count is asserted rather than assumed: if the profile
  -- vanished between the lock and here, the whole call rolls back
  -- rather than leaving a rating with an unmaintained aggregate.
  ----------------------------------------------------------------
  UPDATE public.worker_profiles AS wp
     SET rating_avg = v_avg
   WHERE wp.user_id = v_booking_worker;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'this booking is not available for rating'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 10. RETURN
  --
  -- No private account field is projected. rated_user is the Worker's
  -- id, which N11 already releases to this Client for a completed
  -- Booking, and the average is the value just written.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT v_rating_id, p_booking_id, v_booking_worker, p_score, v_avg;
END;
$$;

COMMENT ON FUNCTION public.rate_my_completed_worker(uuid, integer, text) IS
  'BL-01B: the sole writer of public.ratings. Requires an active '
  'Client account (42501 otherwise), then that the Booking exists, '
  'belongs to the caller, is completed, and has an assigned Worker -- '
  'all four collapsed into the SAME SM409 so the function is not a '
  'Booking-existence oracle, as is a duplicate rating. Score outside '
  '1..5 and a normalised comment over 1000 characters raise 22023, '
  'which reveals nothing about any Booking. rated_by is auth.uid() and '
  'rated_user is the Booking''s worker_id: neither is a parameter, so '
  'identity substitution is unrepresentable rather than merely '
  'rejected. Locks the target worker_profiles row BEFORE inserting, '
  'then recomputes AVG(score) over all rating rows for that Worker and '
  'writes worker_profiles.rating_avg in the same transaction, so '
  'concurrent ratings of one Worker cannot lose an update. Ratings are '
  'immutable: there is no update or delete path. Emits no notification.';

-- Role-by-role revocation before the single grant, so the end state is
-- explicit rather than inherited from PUBLIC defaults.
REVOKE ALL ON FUNCTION public.rate_my_completed_worker(uuid, integer, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.rate_my_completed_worker(uuid, integer, text) FROM anon;

REVOKE ALL ON FUNCTION public.rate_my_completed_worker(uuid, integer, text) FROM authenticated;

REVOKE ALL ON FUNCTION public.rate_my_completed_worker(uuid, integer, text) FROM service_role;

GRANT EXECUTE ON FUNCTION public.rate_my_completed_worker(uuid, integer, text) TO authenticated;


-- ---------- 5. METADATA SYNCHRONISATION ----------
--
-- Comment text only. No column type, default, nullability or
-- constraint is altered, so this is not a D-001 schema expansion.
--
-- worker_profiles.rating_avg had no comment at all while nothing
-- maintained it. It is now maintained, and the one place that fact
-- must be discoverable is the column itself.

COMMENT ON COLUMN public.worker_profiles.rating_avg IS
  'Arithmetic mean of every public.ratings.score for this Worker, '
  'maintained transactionally by public.rate_my_completed_worker() '
  '(BL-01B) and recomputed in full on each rating rather than '
  'incrementally. Protected: an ordinary role cannot change it '
  '(trg_guard_worker_profiles_protected_columns Tier 3). Consumed by '
  'the N8 matching scorer. 0 for a Worker with no ratings -- N8 '
  'decides newness from the EXISTENCE of rating rows, never from this '
  'value, so a genuine average of 0 is impossible (scores are 1..5) '
  'and an unrated Worker is not confused with a badly rated one.';

-- The table comment predated the locked direction and described
-- ratings as flowing "between workers and clients", which is now
-- wrong in both directions it implies.

COMMENT ON TABLE public.ratings IS
  'Client-to-Worker ratings for completed bookings (BL-01B). One '
  'immutable row per (booking_id, rated_by); written only by '
  'public.rate_my_completed_worker(). Worker-to-Client rating is not '
  'implemented.';
