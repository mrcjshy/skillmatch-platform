-- ============================================================
-- N11-DB-01: PARTICIPANT BOOKING LISTS
-- ============================================================
--
-- SCOPE
-- -----
-- Adds the two participant-owned Booking read surfaces:
--
--   public.list_my_worker_bookings()   -- the Worker's own Bookings
--   public.list_my_client_bookings()   -- the Client's own Bookings
--
-- This migration adds TWO FUNCTIONS and nothing else. It creates no
-- table, column, index, trigger or policy, so the locked 11-table ERD
-- (D-001) is untouched, and it modifies no existing object: the Phase 0
-- guards, the matching engine, public.accept_job_opportunity() (N9) and
-- the N10 verification RPCs are all left exactly as they are, including
-- their ACLs.
--
-- WHY AN RPC IS REQUIRED (and why RLS is NOT widened)
-- ---------------------------------------------------
-- A Booking list must name the counterparty, and the counterparty's
-- identity lives in public.users, whose only SELECT policy is
--
--   allow_read_own_profile   USING (auth.uid() = id)
--
-- SELF-ROW ONLY. A Worker therefore cannot read the Client's name or
-- phone, and a Client cannot read the Worker's, by any direct query.
-- The alternative -- widening the users SELECT policy -- would expose
-- every account's contact details to every authenticated user, far
-- beyond Bookings, and is deliberately NOT done here. The users policy,
-- the bookings participant SELECT policy, and every other policy are
-- left byte-for-byte unchanged; these functions are the ONLY new
-- cross-participant identity surface.
--
-- Everything else a Booking list needs (job_postings, job_skills,
-- worker_profiles, worker_skills, ratings) is already readable
-- authenticated-wide, so these functions stay narrow on purpose and
-- must not grow into a general read API.
--
-- TWO SEPARATE AXES -- OWNERSHIP vs STATUS
-- ----------------------------------------
--   participant ownership -> WHETHER YOU CAN LIST THE BOOKING AT ALL
--   booking status        -> WHETHER THE COUNTERPARTY CONTACT/PROFILE
--                            PROJECTION IS RELEASED
--
-- These are kept strictly independent. A Booking the caller owns is
-- ALWAYS listed, in every status, so history never silently disappears
-- -- a completed or cancelled Booking is still the participant's own
-- record. Only the counterparty's contact/profile fields are gated:
--
--   confirmed  -> released      (D-003: contact after a confirmed booking)
--   completed  -> released      (the engagement happened; history is real)
--   pending    -> suppressed
--   cancelled  -> suppressed
--   no_show    -> suppressed
--
-- WHY private.is_active_worker()/is_active_client() ARE REUSED
-- ------------------------------------------------------------
-- Their definitions were read from the catalog rather than assumed from
-- their names. Both test EXACTLY role + is_active:
--
--   is_active_worker(): u.role = 'worker' AND u.is_active = true
--   is_active_client(): u.role = 'client' AND u.is_active = true
--
-- Neither consults is_verified, availability_status or any matching
-- rule. That is precisely the semantics a Booking list needs: a Worker
-- who later becomes unverified, busy or offline has merely stopped
-- being MATCH-ELIGIBLE, and must not lose access to Bookings they
-- already hold. No new helper is introduced.
--
-- RATING FIELDS -- TRANSITIONAL, AGGREGATE ONLY
-- ---------------------------------------------
-- worker_rating_avg / worker_rating_count are computed directly from
-- public.ratings over rated_user, NOT from worker_profiles.rating_avg.
-- That column is nullable with DEFAULT 0 and nothing in the system
-- maintains it (N8-OBS-05, still open and NOT closed here), so reading
-- it would report a stale 0 as though it were a real score.
--
-- With no rating rows the count is 0 and the average is NULL -- never
-- 0, and never N8's neutral 3.0 scoring constant, which is a MATCHING
-- weight and not a rating. A caller can therefore distinguish "no
-- ratings yet" from "rated badly". Only the two aggregates are exposed:
-- rating comments, rated_by and individual scores are never projected.
--
-- This does NOT make the Ratings module secure or complete. Carried
-- forward for the later Ratings piece: public.ratings INSERT is
-- WITH CHECK (rated_by = auth.uid()) with NO Booking-participation
-- test, so any authenticated user can currently rate any user for any
-- booking_id; and public.ratings SELECT is authenticated-wide, so
-- scores and free-text comments are world-readable to any signed-in
-- account. Neither is changed by this migration.
--
-- SECURITY DEFINER SAFETY
-- -----------------------
-- Both functions are SECURITY DEFINER with SET search_path = '', so
-- every object is schema-qualified. There is no dynamic SQL, no
-- caller-controlled identifier, and no parameter at all -- no
-- participant id and no Booking id can be supplied, so one participant
-- cannot enumerate another's Booking list. The caller is always
-- auth.uid().
-- ============================================================


-- ---------- 1. WORKER BOOKING LIST ----------
--
-- STABLE: reads only. plpgsql rather than sql because the caller gate
-- must RAISE -- an authorization failure is an error, while zero rows
-- is an ordinary success meaning "no Bookings yet". The two answers are
-- kept distinguishable, matching the N8-W/N10 convention.

CREATE OR REPLACE FUNCTION public.list_my_worker_bookings()
RETURNS TABLE (
  booking_id       uuid,
  job_id           uuid,
  booking_status   text,
  payment_status   text,
  booked_at        timestamptz,
  completed_at     timestamptz,
  job_title        text,
  job_description  text,
  job_scheduled_at timestamptz,
  job_address      text,
  job_barangay     text,
  job_city         text,
  job_budget       numeric,
  client_user_id   uuid,
  client_full_name text,
  client_phone     text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  ----------------------------------------------------------------
  -- CALLER AUTHORIZATION
  --
  -- Every denial -- signed out, Client, Administrator, or a
  -- deactivated Worker -- raises the SAME error, so a rejected caller
  -- learns nothing about which predicate failed or about any Booking.
  --
  -- The explicit auth.uid() IS NULL test comes first because `anon`
  -- holds neither USAGE on schema private nor EXECUTE on the helper,
  -- so reaching that call unauthenticated would raise a confusing
  -- permission error instead of the intended denial.
  ----------------------------------------------------------------
  IF auth.uid() IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized to view worker bookings'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- OWN BOOKINGS ONLY
  --
  -- worker_id = auth.uid() is the whole row filter; there is no
  -- parameter that could widen it. Newest first, with id as a
  -- deterministic tie-break so two Bookings created in the same
  -- instant cannot reorder between calls.
  --
  -- client_user_id is projected unconditionally: it is the Booking's
  -- own worker_id/client_id pairing, which this participant already
  -- holds by virtue of owning the row. The Client's NAME and PHONE are
  -- the newly released data and are gated on status. The Client's
  -- email is never projected in any status.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT
    b.id,
    b.job_id,
    b.status::text,
    b.payment_status::text,
    b.created_at,
    b.completed_at,
    jp.title::text,
    jp.description,
    jp.scheduled_at,
    jp.address,
    jp.barangay::text,
    jp.city::text,
    jp.budget,
    b.client_id,
    CASE WHEN b.status IN ('confirmed', 'completed') THEN cu.full_name END,
    CASE WHEN b.status IN ('confirmed', 'completed') THEN cu.phone END
  FROM public.bookings AS b
  JOIN public.job_postings AS jp
    ON jp.id = b.job_id
  JOIN public.users AS cu
    ON cu.id = b.client_id
  WHERE b.worker_id = auth.uid()
  ORDER BY b.created_at DESC, b.id DESC;
END;
$$;


COMMENT ON FUNCTION public.list_my_worker_bookings() IS
  'N11-DB-01: the calling Worker''s own Bookings. Requires an active '
  'Worker account (private.is_active_worker(): role + is_active only, '
  'NOT verification or availability, so Booking history survives a loss '
  'of match eligibility); every other caller receives 42501 "not '
  'authorized to view worker bookings". SECURITY DEFINER because '
  'public.users SELECT is self-row only, so the Client''s identity is '
  'otherwise unreadable; this does not widen any policy. Takes no '
  'parameter, so no other Worker''s list can be enumerated. Rows are '
  'worker_id = auth.uid() in EVERY status, newest first. Client '
  'full_name and phone are released only while the Booking is '
  'confirmed or completed and are NULL otherwise; Client email is never '
  'projected.';


-- Role-by-role revocation is required: schema public grants EXECUTE on
-- every new function to anon, authenticated and service_role by name,
-- so REVOKE ... FROM PUBLIC alone would leave them in place
-- (docs/SECURITY.md GAP-004). service_role stays revoked because it has
-- no auth.uid() and could never pass the caller gate.

REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM anon;

REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM authenticated;

REVOKE ALL ON FUNCTION public.list_my_worker_bookings() FROM service_role;

GRANT EXECUTE ON FUNCTION public.list_my_worker_bookings() TO authenticated;


-- ---------- 2. CLIENT BOOKING LIST ----------

CREATE OR REPLACE FUNCTION public.list_my_client_bookings()
RETURNS TABLE (
  booking_id          uuid,
  job_id              uuid,
  booking_status      text,
  payment_status      text,
  booked_at           timestamptz,
  completed_at        timestamptz,
  job_title           text,
  job_description     text,
  job_scheduled_at    timestamptz,
  job_address         text,
  job_barangay        text,
  job_city            text,
  job_budget          numeric,
  worker_user_id      uuid,
  worker_full_name    text,
  worker_phone        text,
  worker_barangay     text,
  worker_skills       text[],
  worker_is_verified  boolean,
  worker_rating_avg   numeric,
  worker_rating_count integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_active_client() THEN
    RAISE EXCEPTION 'not authorized to view client bookings'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- OWN BOOKINGS ONLY
  --
  -- The Worker profile block (name, phone, barangay, skills,
  -- verification, ratings) is released as ONE unit, gated by the same
  -- status test, so no field can leak while a sibling is suppressed.
  --
  -- worker_skills is deliberately three-valued:
  --   NULL  -> the profile projection is suppressed for this status
  --   '{}'  -> released, and the Worker genuinely has no skills
  --   {...} -> released, deterministic alphabetical, de-duplicated
  -- That keeps "not released" distinguishable from "released but
  -- empty". DISTINCT plus the ordered aggregate guarantee no duplicate
  -- name and a stable order across calls.
  --
  -- Ratings are aggregates over public.ratings.rated_user: never
  -- worker_profiles.rating_avg (unmaintained, N8-OBS-05), never a
  -- neutral constant. With no rating rows the count is 0 and the
  -- average is NULL, so a caller can tell "no ratings yet" apart from a
  -- low score. Individual scores, comments and rated_by are never
  -- projected. verified_by is never projected.
  ----------------------------------------------------------------
  RETURN QUERY
  SELECT
    b.id,
    b.job_id,
    b.status::text,
    b.payment_status::text,
    b.created_at,
    b.completed_at,
    jp.title::text,
    jp.description,
    jp.scheduled_at,
    jp.address,
    jp.barangay::text,
    jp.city::text,
    jp.budget,
    b.worker_id,
    CASE WHEN b.status IN ('confirmed', 'completed') THEN wu.full_name END,
    CASE WHEN b.status IN ('confirmed', 'completed') THEN wu.phone END,
    CASE WHEN b.status IN ('confirmed', 'completed') THEN wu.barangay END,
    CASE
      WHEN b.status IN ('confirmed', 'completed') THEN
        COALESCE(
          (
            SELECT array_agg(DISTINCT sk.skill_name::text ORDER BY sk.skill_name::text)
            FROM public.worker_profiles AS wp
            JOIN public.worker_skills AS ws
              ON ws.worker_id = wp.id
            JOIN public.skills AS sk
              ON sk.id = ws.skill_id
            WHERE wp.user_id = b.worker_id
          ),
          '{}'::text[]
        )
    END,
    CASE
      WHEN b.status IN ('confirmed', 'completed') THEN
        (
          SELECT wp.is_verified
          FROM public.worker_profiles AS wp
          WHERE wp.user_id = b.worker_id
        )
    END,
    CASE
      WHEN b.status IN ('confirmed', 'completed') THEN
        (
          SELECT avg(rt.score)::numeric
          FROM public.ratings AS rt
          WHERE rt.rated_user = b.worker_id
        )
    END,
    CASE
      WHEN b.status IN ('confirmed', 'completed') THEN
        (
          SELECT count(*)::integer
          FROM public.ratings AS rt
          WHERE rt.rated_user = b.worker_id
        )
    END
  FROM public.bookings AS b
  JOIN public.job_postings AS jp
    ON jp.id = b.job_id
  JOIN public.users AS wu
    ON wu.id = b.worker_id
  WHERE b.client_id = auth.uid()
  ORDER BY b.created_at DESC, b.id DESC;
END;
$$;


COMMENT ON FUNCTION public.list_my_client_bookings() IS
  'N11-DB-01: the calling Client''s own Bookings. Requires an active '
  'Client account (private.is_active_client()); every other caller '
  'receives 42501 "not authorized to view client bookings". SECURITY '
  'DEFINER because public.users SELECT is self-row only; no policy is '
  'widened. Takes no parameter, so no other Client''s list can be '
  'enumerated. Rows are client_id = auth.uid() in EVERY status, newest '
  'first. The Worker profile projection (full_name, phone, barangay, '
  'skills, is_verified, rating_avg, rating_count) is released as one '
  'unit only while the Booking is confirmed or completed, and is NULL '
  'otherwise; worker_skills is NULL when suppressed and ''{}'' when '
  'released for a Worker with no skills. Ratings are aggregates over '
  'public.ratings (count 0 with a NULL average when unrated), never the '
  'unmaintained worker_profiles.rating_avg; comments, individual scores '
  'and rated_by are never projected, and neither is Worker email or '
  'verified_by.';


REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM anon;

REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM authenticated;

REVOKE ALL ON FUNCTION public.list_my_client_bookings() FROM service_role;

GRANT EXECUTE ON FUNCTION public.list_my_client_bookings() TO authenticated;
