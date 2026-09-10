-- ============================================================
-- R3-DB-01: USER REPORTS (public.reports)
-- ============================================================
--
-- SCOPE
-- -----
-- Adds the 12th application table public.reports and the trusted
-- write/read/review boundary for counterpart reports and app issues.
-- This is the D-001 amendment authorized for R3: one new table, no
-- manuscript/ERD/DFD edit, no automatic punishment, no notification
-- type, and no Admin message access.
--
-- This migration:
--   1. creates public.reports with class, description, category,
--      status, admin-response and admin-lifecycle CHECKs
--   2. adds the partial unique index that atomically forbids two
--      active counterpart reports by the same reporter on one Booking
--   3. enables RLS, normalizes table grants to authenticated SELECT
--      only, and adds the reporter-only SELECT policy
--   4. adds public.submit_my_booking_report()
--   5. adds public.submit_my_app_issue()
--   6. adds public.list_reports()
--   7. adds public.get_report()
--   8. adds public.review_report()
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No users.is_active, worker_profiles.strike_count, bookings.status,
--     job_postings.status, ratings or payments mutation.
--   * No notification row and no change to notifications_type_check.
--   * No Admin SELECT policy on public.messages, no message dump in
--     get_report(), no evidence column. Report-scoped Admin message
--     evidence remains R3B.
--   * No FORCE ROW LEVEL SECURITY. public.reports is owned by postgres
--     and relforcerowsecurity stays false, so postgres-owned SECURITY
--     DEFINER RPCs are not subject to RLS on this table (the same
--     owner-bypass N10/N12 document). Admin list/get/review therefore
--     work with no Admin table-wide SELECT policy, which is the point:
--     Administrators do not read reports through PostgREST table
--     access.
--   * No updated_at, evidence_text, JSON metadata, attachments, strike
--     or suspension columns.
--   * Reporting eligibility is ROLE-BASED. private.is_active_worker()
--     and private.is_active_client() are not used. A Worker or Client
--     with users.is_active = false may still submit.
--
-- ERROR CLASSES (existing project convention)
-- -------------------------------------------
--   42501  not authorized (signed out, wrong role, non-admin)
--   22023  invalid caller-supplied parameter (category, description,
--          review status, admin response)
--   SM409  collapsed "not available" / current-state conflict
--
-- SM409 deliberately collapses: nonexistent Booking, Booking the
-- caller does not participate in, a Booking whose status is not
-- reportable, a duplicate active counterpart report, a missing report,
-- and an illegal review transition. The booking-submit RPC is not a
-- Booking-existence oracle.
-- ============================================================


-- ---------- 1. TABLE ----------

CREATE TABLE public.reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  reported_user_id uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  booking_id uuid REFERENCES public.bookings(id) ON DELETE RESTRICT,
  category text NOT NULL,
  description text NOT NULL,
  status text NOT NULL DEFAULT 'submitted',
  admin_response text,
  reviewed_by uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reports_category_check CHECK (
    category = ANY (
      ARRAY[
        'behavior',
        'no-show',
        'harassment',
        'safety',
        'payment',
        'incorrect_details',
        'fraud',
        'app_issue',
        'other'
      ]::text[]
    )
  ),
  CONSTRAINT reports_status_check CHECK (
    status = ANY (
      ARRAY[
        'submitted',
        'under_review',
        'resolved',
        'dismissed'
      ]::text[]
    )
  ),
  CONSTRAINT reports_description_check CHECK (
    length(btrim(description)) BETWEEN 1 AND 2000
  ),
  CONSTRAINT reports_admin_response_check CHECK (
    admin_response IS NULL
    OR length(btrim(admin_response)) BETWEEN 1 AND 2000
  ),
  CONSTRAINT reports_class_check CHECK (
    (
      category <> 'app_issue'
      AND booking_id IS NOT NULL
      AND reported_user_id IS NOT NULL
      AND reporter_id <> reported_user_id
    )
    OR
    (
      category = 'app_issue'
      AND booking_id IS NULL
      AND reported_user_id IS NULL
    )
  ),
  CONSTRAINT reports_admin_lifecycle_check CHECK (
    (
      status = 'submitted'
      AND admin_response IS NULL
      AND reviewed_by IS NULL
      AND reviewed_at IS NULL
    )
    OR
    (
      status = 'under_review'
      AND reviewed_by IS NOT NULL
      AND reviewed_at IS NOT NULL
    )
    OR
    (
      status IN ('resolved', 'dismissed')
      AND reviewed_by IS NOT NULL
      AND reviewed_at IS NOT NULL
      AND admin_response IS NOT NULL
      AND length(btrim(admin_response)) BETWEEN 1 AND 2000
    )
  )
);

ALTER TABLE public.reports OWNER TO postgres;

COMMENT ON TABLE public.reports IS
  'R3: counterpart reports (Booking-bound) and general app issues. '
  'Written only by submit_my_booking_report / submit_my_app_issue; '
  'reviewed only by review_report. No automatic punishment.';

COMMENT ON COLUMN public.reports.reporter_id IS
  'auth.uid() of the submitting Worker or Client. Never caller-supplied.';

COMMENT ON COLUMN public.reports.reported_user_id IS
  'Opposite Booking participant, server-derived. NULL for app issues.';

COMMENT ON COLUMN public.reports.booking_id IS
  'Required for counterpart reports. NULL for app issues.';

COMMENT ON COLUMN public.reports.category IS
  'CHECK-on-text: behavior, no-show, harassment, safety, payment, '
  'incorrect_details, fraud, app_issue, other. no-show is a report '
  'category, not a requirement that Booking.status = no_show.';

COMMENT ON COLUMN public.reports.status IS
  'CHECK-on-text: submitted (default), under_review, resolved, dismissed.';

COMMENT ON COLUMN public.reports.admin_response IS
  'NULL while submitted. Optional on under_review. Required and '
  'nonblank 1..2000 on resolved/dismissed.';


-- ---------- 2. DUPLICATE ACTIVE COUNTERPART REPORTS ----------
--
-- Same reporter + same Booking cannot have two rows that are still
-- submitted or under_review. After resolved or dismissed the predicate
-- no longer matches, so a new report for that Booking is allowed.
-- App issues have booking_id NULL and are excluded.

CREATE UNIQUE INDEX reports_one_active_counterpart_per_reporter_booking
  ON public.reports (reporter_id, booking_id)
  WHERE booking_id IS NOT NULL
    AND status IN ('submitted', 'under_review');

COMMENT ON INDEX public.reports_one_active_counterpart_per_reporter_booking IS
  'R3: at most one active counterpart report per (reporter_id, booking_id).';


-- ---------- 3. RLS AND DIRECT TABLE PRIVILEGES ----------
--
-- ALTER DEFAULT PRIVILEGES in the baseline grants ALL on new public
-- tables to anon, authenticated and service_role. Those grants are
-- stripped here for client roles. authenticated is granted SELECT
-- only. No INSERT/UPDATE/DELETE grant and no corresponding policy:
-- direct DML fails at the GRANT layer (GAP-004 discipline).
--
-- service_role is not given an extra explicit grant. The postgres
-- owner entry is untouched.

ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.reports FROM PUBLIC;

REVOKE ALL ON TABLE public.reports FROM anon;

REVOKE ALL ON TABLE public.reports FROM authenticated;

GRANT SELECT ON TABLE public.reports TO authenticated;

CREATE POLICY "Reporters can read their own reports"
  ON public.reports
  FOR SELECT
  TO authenticated
  USING (reporter_id = auth.uid());

COMMENT ON POLICY "Reporters can read their own reports" ON public.reports IS
  'R3: a report row is directly readable only by its reporter. The '
  'reported party and every unrelated caller receive zero rows. There '
  'is no Admin table-wide SELECT policy; Administrators use list_reports '
  '/ get_report. There is no UPDATE or DELETE policy.';


-- ---------- 4. WORKER/CLIENT COUNTERPART SUBMIT ----------
--
-- The caller supplies Booking, category and description only.
-- reporter_id is auth.uid(); reported_user_id is the opposite
-- participant read from the Booking. Identity substitution is
-- unrepresentable rather than merely rejected.

CREATE OR REPLACE FUNCTION public.submit_my_booking_report(
  p_booking_id uuid,
  p_category text,
  p_description text
)
RETURNS TABLE (report_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller          uuid := auth.uid();
  v_role            text;
  v_category        text;
  v_description     text;
  v_booking_status  text;
  v_booking_worker  uuid;
  v_booking_client  uuid;
  v_reported        uuid;
  v_report_id       uuid;
BEGIN
  ----------------------------------------------------------------
  -- 1. CALLER AUTHORIZATION (role, not is_active)
  --
  -- Signed out, Administrator, missing users row, and any role
  -- other than worker/client raise the SAME 42501. is_active is
  -- deliberately unread: an inactive Worker or Client may still
  -- submit a legitimate counterpart report.
  ----------------------------------------------------------------
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to submit booking reports'
      USING ERRCODE = '42501';
  END IF;

  SELECT u.role::text
    INTO v_role
  FROM public.users AS u
  WHERE u.id = v_caller;

  IF NOT FOUND OR v_role NOT IN ('worker', 'client') THEN
    RAISE EXCEPTION 'not authorized to submit booking reports'
      USING ERRCODE = '42501';
  END IF;

  ----------------------------------------------------------------
  -- 2. CALLER-SUPPLIED INPUT, BEFORE ANY BOOKING IS READ
  --
  -- 22023 discloses nothing about any Booking. app_issue is rejected
  -- here because that class has its own RPC.
  ----------------------------------------------------------------
  v_category := NULLIF(btrim(COALESCE(p_category, '')), '');

  IF v_category IS NULL
     OR v_category = 'app_issue'
     OR v_category NOT IN (
          'behavior',
          'no-show',
          'harassment',
          'safety',
          'payment',
          'incorrect_details',
          'fraud',
          'other'
        )
  THEN
    RAISE EXCEPTION 'report category is not valid'
      USING ERRCODE = '22023';
  END IF;

  v_description := btrim(COALESCE(p_description, ''));

  IF length(v_description) < 1 OR length(v_description) > 2000 THEN
    RAISE EXCEPTION 'report description must be between 1 and 2000 characters'
      USING ERRCODE = '22023';
  END IF;

  ----------------------------------------------------------------
  -- 3. RESOLVE THE BOOKING
  ----------------------------------------------------------------
  SELECT b.status::text, b.worker_id, b.client_id
    INTO v_booking_status, v_booking_worker, v_booking_client
  FROM public.bookings AS b
  WHERE b.id = p_booking_id;

  ----------------------------------------------------------------
  -- 4. PARTICIPANT + REPORTABLE STATUS, ONE ERROR
  --
  -- Nonexistent, not the caller's side, pending, no_show, and a
  -- missing opposite participant all collapse to SM409.
  ----------------------------------------------------------------
  IF NOT FOUND
     OR v_booking_status NOT IN ('confirmed', 'completed', 'cancelled')
     OR (v_role = 'worker' AND v_booking_worker IS DISTINCT FROM v_caller)
     OR (v_role = 'client' AND v_booking_client IS DISTINCT FROM v_caller)
  THEN
    RAISE EXCEPTION 'this booking is not available for reporting'
      USING ERRCODE = 'SM409';
  END IF;

  IF v_role = 'worker' THEN
    v_reported := v_booking_client;
  ELSE
    v_reported := v_booking_worker;
  END IF;

  IF v_reported IS NULL OR v_reported = v_caller THEN
    RAISE EXCEPTION 'this booking is not available for reporting'
      USING ERRCODE = 'SM409';
  END IF;

  ----------------------------------------------------------------
  -- 5. INSERT — identities and Admin fields are server-owned
  --
  -- unique_violation is the duplicate active counterpart report
  -- (partial unique index). Re-raised as SM409 so the caller never
  -- sees 23505 or the index name, and so a non-participant still
  -- cannot distinguish "duplicate of a Booking I am not on".
  -- Duplicate is only reachable after participation is proven, but
  -- the conflict class stays SM409 per contract.
  ----------------------------------------------------------------
  BEGIN
    INSERT INTO public.reports (
      reporter_id,
      reported_user_id,
      booking_id,
      category,
      description,
      status,
      admin_response,
      reviewed_by,
      reviewed_at
    )
    VALUES (
      v_caller,
      v_reported,
      p_booking_id,
      v_category,
      v_description,
      'submitted',
      NULL,
      NULL,
      NULL
    )
    RETURNING id INTO v_report_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'this booking is not available for reporting'
        USING ERRCODE = 'SM409';
  END;

  RETURN QUERY SELECT v_report_id;
END;
$$;

COMMENT ON FUNCTION public.submit_my_booking_report(uuid, text, text) IS
  'R3: Worker or Client counterpart report on a Booking they actually '
  'participate in. Role-based (worker/client), including inactive '
  'accounts; 42501 otherwise. Category must be a non-app_issue allowed '
  'value and description must trim to 1..2000 (22023). Booking must '
  'exist, name the caller as worker_id or client_id matching their '
  'role, and be confirmed/completed/cancelled — otherwise SM409, as is '
  'a duplicate active report. reported_user_id is the opposite '
  'participant and is not a parameter. Forces status submitted and '
  'NULL Admin fields. Writes no users.is_active, strike_count, Booking, '
  'Job, rating, payment or notification.';

REVOKE ALL ON FUNCTION public.submit_my_booking_report(uuid, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.submit_my_booking_report(uuid, text, text) FROM anon;

REVOKE ALL ON FUNCTION public.submit_my_booking_report(uuid, text, text) FROM authenticated;

REVOKE ALL ON FUNCTION public.submit_my_booking_report(uuid, text, text) FROM service_role;

GRANT EXECUTE ON FUNCTION public.submit_my_booking_report(uuid, text, text) TO authenticated;


-- ---------- 5. APP ISSUE SUBMIT ----------

CREATE OR REPLACE FUNCTION public.submit_my_app_issue(
  p_description text
)
RETURNS TABLE (report_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_role        text;
  v_description text;
  v_report_id   uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to submit app issues'
      USING ERRCODE = '42501';
  END IF;

  SELECT u.role::text
    INTO v_role
  FROM public.users AS u
  WHERE u.id = v_caller;

  IF NOT FOUND OR v_role NOT IN ('worker', 'client') THEN
    RAISE EXCEPTION 'not authorized to submit app issues'
      USING ERRCODE = '42501';
  END IF;

  v_description := btrim(COALESCE(p_description, ''));

  IF length(v_description) < 1 OR length(v_description) > 2000 THEN
    RAISE EXCEPTION 'report description must be between 1 and 2000 characters'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.reports (
    reporter_id,
    reported_user_id,
    booking_id,
    category,
    description,
    status,
    admin_response,
    reviewed_by,
    reviewed_at
  )
  VALUES (
    v_caller,
    NULL,
    NULL,
    'app_issue',
    v_description,
    'submitted',
    NULL,
    NULL,
    NULL
  )
  RETURNING id INTO v_report_id;

  RETURN QUERY SELECT v_report_id;
END;
$$;

COMMENT ON FUNCTION public.submit_my_app_issue(text) IS
  'R3: general app issue from an authenticated Worker or Client, '
  'including inactive accounts. 42501 for every other caller. Category '
  'is forced to app_issue; booking_id and reported_user_id are forced '
  'NULL. Description must trim to 1..2000 (22023). Repeatable. Forces '
  'status submitted and NULL Admin fields. Writes no punishment, '
  'Booking, Job, rating, payment or notification.';

REVOKE ALL ON FUNCTION public.submit_my_app_issue(text) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.submit_my_app_issue(text) FROM anon;

REVOKE ALL ON FUNCTION public.submit_my_app_issue(text) FROM authenticated;

REVOKE ALL ON FUNCTION public.submit_my_app_issue(text) FROM service_role;

GRANT EXECUTE ON FUNCTION public.submit_my_app_issue(text) TO authenticated;


-- ---------- 6. ADMIN LIST ----------
--
-- STABLE. SECURITY DEFINER because public.users SELECT is self-row
-- only, so reporter/reported names are otherwise unreadable, and
-- because there is no Admin table-wide SELECT on public.reports.
-- Zero rows means nothing to list, never a denial.

CREATE OR REPLACE FUNCTION public.list_reports()
RETURNS TABLE (
  report_id            uuid,
  reporter_id          uuid,
  reporter_full_name   text,
  reported_user_id     uuid,
  reported_full_name   text,
  booking_id           uuid,
  category             text,
  status               text,
  created_at           timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to list reports'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.reporter_id,
    reporter.full_name,
    r.reported_user_id,
    reported.full_name,
    r.booking_id,
    r.category,
    r.status,
    r.created_at
  FROM public.reports AS r
  JOIN public.users AS reporter
    ON reporter.id = r.reporter_id
  LEFT JOIN public.users AS reported
    ON reported.id = r.reported_user_id
  ORDER BY r.created_at DESC, r.id DESC;
END;
$$;

COMMENT ON FUNCTION public.list_reports() IS
  'R3: Administrator list of reports, newest first. Requires '
  'private.is_admin(); every other caller receives 42501. Returns id, '
  'reporter id/name, reported id/name (nullable), booking id '
  '(nullable), category, status and created_at. No phone, email, '
  'address, description or message history.';

REVOKE ALL ON FUNCTION public.list_reports() FROM PUBLIC;

REVOKE ALL ON FUNCTION public.list_reports() FROM anon;

REVOKE ALL ON FUNCTION public.list_reports() FROM authenticated;

REVOKE ALL ON FUNCTION public.list_reports() FROM service_role;

GRANT EXECUTE ON FUNCTION public.list_reports() TO authenticated;


-- ---------- 7. ADMIN DETAIL ----------

CREATE OR REPLACE FUNCTION public.get_report(p_report_id uuid)
RETURNS TABLE (
  report_id            uuid,
  reporter_id          uuid,
  reporter_full_name   text,
  reported_user_id     uuid,
  reported_full_name   text,
  booking_id           uuid,
  job_title            text,
  category             text,
  description          text,
  status               text,
  admin_response       text,
  reviewed_by          uuid,
  reviewed_at          timestamptz,
  created_at           timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to view reports'
      USING ERRCODE = '42501';
  END IF;

  PERFORM 1
  FROM public.reports AS r
  WHERE r.id = p_report_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'this report is not available'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.reporter_id,
    reporter.full_name,
    r.reported_user_id,
    reported.full_name,
    r.booking_id,
    jp.title::text,
    r.category,
    r.description,
    r.status,
    r.admin_response,
    r.reviewed_by,
    r.reviewed_at,
    r.created_at
  FROM public.reports AS r
  JOIN public.users AS reporter
    ON reporter.id = r.reporter_id
  LEFT JOIN public.users AS reported
    ON reported.id = r.reported_user_id
  LEFT JOIN public.bookings AS b
    ON b.id = r.booking_id
  LEFT JOIN public.job_postings AS jp
    ON jp.id = b.job_id
  WHERE r.id = p_report_id;
END;
$$;

COMMENT ON FUNCTION public.get_report(uuid) IS
  'R3: Administrator detail of one report. Requires private.is_admin(); '
  'every other caller receives 42501. Missing id returns SM409. '
  'Returns names, optional job title, description, status and Admin '
  'lifecycle fields. No phone, email, address or message dump.';

REVOKE ALL ON FUNCTION public.get_report(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.get_report(uuid) FROM anon;

REVOKE ALL ON FUNCTION public.get_report(uuid) FROM authenticated;

REVOKE ALL ON FUNCTION public.get_report(uuid) FROM service_role;

GRANT EXECUTE ON FUNCTION public.get_report(uuid) TO authenticated;


-- ---------- 8. ADMIN REVIEW ----------
--
-- Allowed transitions:
--   submitted    -> under_review | resolved | dismissed
--   under_review -> resolved | dismissed
-- Denied:
--   under_review -> submitted
--   resolved / dismissed -> anything
--   same-state rewrite
-- Terminal retry/conflict: SM409.
--
-- This function UPDATEs only reports.status, admin_response,
-- reviewed_by and reviewed_at. It never writes public.users,
-- worker_profiles, bookings, job_postings, ratings, payments or
-- notifications.

CREATE OR REPLACE FUNCTION public.review_report(
  p_report_id uuid,
  p_status text,
  p_admin_response text DEFAULT NULL
)
RETURNS TABLE (
  report_id      uuid,
  status         text,
  reviewed_by    uuid,
  reviewed_at    timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller          uuid := auth.uid();
  v_target_status   text;
  v_new_response    text;
  v_current_status  text;
  v_current_response text;
  v_final_response  text;
  v_reviewed_at     timestamptz;
BEGIN
  IF v_caller IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to review reports'
      USING ERRCODE = '42501';
  END IF;

  v_target_status := NULLIF(btrim(COALESCE(p_status, '')), '');

  IF v_target_status IS NULL
     OR v_target_status NOT IN ('under_review', 'resolved', 'dismissed')
  THEN
    RAISE EXCEPTION 'report review status is not valid'
      USING ERRCODE = '22023';
  END IF;

  v_new_response := NULLIF(btrim(COALESCE(p_admin_response, '')), '');

  IF v_new_response IS NOT NULL AND length(v_new_response) > 2000 THEN
    RAISE EXCEPTION 'admin response must be between 1 and 2000 characters'
      USING ERRCODE = '22023';
  END IF;

  SELECT r.status, r.admin_response
    INTO v_current_status, v_current_response
  FROM public.reports AS r
  WHERE r.id = p_report_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'this report is not available for review'
      USING ERRCODE = 'SM409';
  END IF;

  IF v_current_status = v_target_status
     OR v_current_status IN ('resolved', 'dismissed')
     OR NOT (
          (v_current_status = 'submitted'
           AND v_target_status IN ('under_review', 'resolved', 'dismissed'))
          OR
          (v_current_status = 'under_review'
           AND v_target_status IN ('resolved', 'dismissed'))
        )
  THEN
    RAISE EXCEPTION 'this report is not available for review'
      USING ERRCODE = 'SM409';
  END IF;

  IF v_target_status = 'under_review' THEN
    v_final_response := v_new_response;
  ELSE
    v_final_response := COALESCE(
      v_new_response,
      NULLIF(btrim(COALESCE(v_current_response, '')), '')
    );

    IF v_final_response IS NULL
       OR length(v_final_response) < 1
       OR length(v_final_response) > 2000
    THEN
      RAISE EXCEPTION 'admin response is required to resolve or dismiss a report'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE public.reports AS r
     SET status = v_target_status,
         admin_response = v_final_response,
         reviewed_by = v_caller,
         reviewed_at = now()
   WHERE r.id = p_report_id
   RETURNING r.reviewed_at INTO v_reviewed_at;

  RETURN QUERY
  SELECT p_report_id, v_target_status, v_caller, v_reviewed_at;
END;
$$;

COMMENT ON FUNCTION public.review_report(uuid, text, text) IS
  'R3: Administrator review of one report. Requires private.is_admin(); '
  '42501 otherwise. submitted may move to under_review, resolved or '
  'dismissed; under_review may move to resolved or dismissed. Same-state '
  'rewrite and any write to a terminal row return SM409. under_review '
  'response is optional (1..2000 if supplied); resolved/dismissed require '
  'a nonblank 1..2000 response, preserving a valid existing one when the '
  'caller omits a new value. Sets reviewed_by = auth.uid() and '
  'reviewed_at = now(). Never mutates users.is_active, strike_count, '
  'Booking status, Job status, ratings or payments. Emits no notification.';

REVOKE ALL ON FUNCTION public.review_report(uuid, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.review_report(uuid, text, text) FROM anon;

REVOKE ALL ON FUNCTION public.review_report(uuid, text, text) FROM authenticated;

REVOKE ALL ON FUNCTION public.review_report(uuid, text, text) FROM service_role;

GRANT EXECUTE ON FUNCTION public.review_report(uuid, text, text) TO authenticated;
