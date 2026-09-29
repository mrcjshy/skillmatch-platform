-- FT-05 #11: Administrator-reviewed no-show strikes and threshold suspension.
-- Submission and ordinary review_report remain non-disciplinary.

CREATE OR REPLACE FUNCTION public.get_report_discipline_state(p_report_id uuid)
RETURNS TABLE (
  eligible boolean,
  current_strike_count integer,
  would_suspend boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to view report discipline state'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.reports AS r WHERE r.id = p_report_id) THEN
    RAISE EXCEPTION 'this report is not available'
      USING ERRCODE = 'SM409';
  END IF;

  RETURN QUERY
  SELECT
    (
      r.booking_id IS NOT NULL
      AND r.category = 'no-show'
      AND r.status IN ('submitted', 'under_review')
      AND u.role = 'worker'
      AND wp.user_id IS NOT NULL
      AND wp.strike_count < 3
    ) AS eligible,
    CASE
      WHEN u.role = 'worker' AND wp.user_id IS NOT NULL THEN wp.strike_count
      ELSE NULL
    END AS current_strike_count,
    (
      r.booking_id IS NOT NULL
      AND r.category = 'no-show'
      AND r.status IN ('submitted', 'under_review')
      AND u.role = 'worker'
      AND wp.user_id IS NOT NULL
      AND wp.strike_count = 2
      AND u.is_active = true
    ) AS would_suspend
  FROM public.reports AS r
  LEFT JOIN public.users AS u ON u.id = r.reported_user_id
  LEFT JOIN public.worker_profiles AS wp ON wp.user_id = r.reported_user_id
  WHERE r.id = p_report_id;
END;
$$;

COMMENT ON FUNCTION public.get_report_discipline_state(uuid) IS
  'FT-05 #11: active-Administrator-only advisory read for one report. Returns only eligibility, current Worker strike count when applicable, and whether this action would actually flip an active Worker inactive. It exposes no Worker id and grants no mutation authority. Missing is collapsed SM409.';

ALTER FUNCTION public.get_report_discipline_state(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_report_discipline_state(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_report_discipline_state(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.resolve_no_show_report_with_strike(
  p_report_id uuid,
  p_admin_response text
)
RETURNS TABLE (
  report_id uuid,
  status text,
  strike_count integer,
  is_active boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_response text;
  v_report_category text;
  v_report_status text;
  v_booking_id uuid;
  v_worker_id uuid;
  v_profile_id uuid;
  v_old_strike_count integer;
  v_new_strike_count integer;
  v_worker_role text;
  v_was_active boolean;
  v_is_active boolean;
  v_suspended boolean := false;
BEGIN
  IF v_caller IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to apply report discipline'
      USING ERRCODE = '42501';
  END IF;

  v_response := nullif(btrim(coalesce(p_admin_response, '')), '');
  IF v_response IS NULL OR char_length(v_response) > 2000 THEN
    RAISE EXCEPTION 'admin response must be between 1 and 2000 characters'
      USING ERRCODE = '22023';
  END IF;

  -- Lock 1: Report.
  SELECT r.category, r.status, r.booking_id, r.reported_user_id
    INTO v_report_category, v_report_status, v_booking_id, v_worker_id
  FROM public.reports AS r
  WHERE r.id = p_report_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_booking_id IS NULL
     OR v_report_category IS DISTINCT FROM 'no-show'
     OR v_report_status NOT IN ('submitted', 'under_review')
     OR v_worker_id IS NULL
  THEN
    RAISE EXCEPTION 'this report is not available for no-show discipline'
      USING ERRCODE = 'SM409';
  END IF;

  -- Lock 2: Worker profile. The reported identity comes only from the Report.
  SELECT wp.id, wp.strike_count
    INTO v_profile_id, v_old_strike_count
  FROM public.worker_profiles AS wp
  WHERE wp.user_id = v_worker_id
  FOR UPDATE;

  IF NOT FOUND OR v_old_strike_count >= 3 THEN
    RAISE EXCEPTION 'this report is not available for no-show discipline'
      USING ERRCODE = 'SM409';
  END IF;

  -- Lock 3: User. Read role and active state only after acquiring this lock.
  SELECT u.role::text, u.is_active
    INTO v_worker_role, v_was_active
  FROM public.users AS u
  WHERE u.id = v_worker_id
  FOR UPDATE;

  IF NOT FOUND OR v_worker_role IS DISTINCT FROM 'worker' THEN
    RAISE EXCEPTION 'this report is not available for no-show discipline'
      USING ERRCODE = 'SM409';
  END IF;

  v_new_strike_count := v_old_strike_count + 1;

  UPDATE public.worker_profiles AS wp
     SET strike_count = v_new_strike_count
   WHERE wp.id = v_profile_id;

  UPDATE public.reports AS r
     SET status = 'resolved',
         admin_response = v_response,
         reviewed_by = v_caller,
         reviewed_at = now()
   WHERE r.id = p_report_id;

  IF v_new_strike_count = 3 AND v_was_active THEN
    UPDATE public.users AS u
       SET is_active = false
     WHERE u.id = v_worker_id;
    v_suspended := true;
    v_is_active := false;
  ELSE
    -- Never reactivate an account that was already inactive.
    v_is_active := v_was_active;
  END IF;

  PERFORM private.emit_notification(
    v_worker_id,
    'no_show_strike',
    'An Administrator applied a no-show strike after reviewing a report.'
  );

  IF v_suspended THEN
    PERFORM private.emit_notification(
      v_worker_id,
      'account_suspended',
      'Your Worker account is suspended after reaching three reviewed no-show strikes.'
    );
  END IF;

  RETURN QUERY
  SELECT r.id, r.status::text, wp.strike_count, u.is_active
  FROM public.reports AS r
  JOIN public.worker_profiles AS wp ON wp.id = v_profile_id
  JOIN public.users AS u ON u.id = v_worker_id
  WHERE r.id = p_report_id;
END;
$$;

COMMENT ON FUNCTION public.resolve_no_show_report_with_strike(uuid,text) IS
  'FT-05 #11: narrow active-Administrator disciplinary action. Inputs are Report id and bounded response only. Locks Report, then server-derived Worker profile, then User; accepts only Booking-bound submitted/under_review no-show reports against a Worker below three strikes. Increments once, resolves with auth.uid()/database time, never reactivates, and flips true to false only on 2->3. Emits exactly one fixed no_show_strike and an account_suspended notification only on the actual active-to-inactive flip. Notification failure rolls back every write.';

ALTER FUNCTION public.resolve_no_show_report_with_strike(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.resolve_no_show_report_with_strike(uuid,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_no_show_report_with_strike(uuid,text) TO authenticated;
