-- V5-FIX: durable, server-owned report outcome used for privacy-safe email retry.
-- No new table or caller-controlled disciplinary input is introduced.

ALTER TABLE public.reports
  ADD COLUMN disciplinary_outcome text;

ALTER TABLE public.reports
  ADD CONSTRAINT reports_disciplinary_outcome_check
  CHECK (
    disciplinary_outcome IS NULL
    OR disciplinary_outcome IN ('no_show_strike', 'account_suspended')
  );

COMMENT ON COLUMN public.reports.disciplinary_outcome IS
  'V5: server-owned outcome written only by resolve_no_show_report_with_strike. NULL means no disciplinary action; no_show_strike means a strike without a newly caused suspension; account_suspended means this report caused an active-to-inactive third-strike transition.';

REVOKE UPDATE (disciplinary_outcome) ON TABLE public.reports
  FROM PUBLIC, anon, authenticated;


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
  v_disciplinary_outcome text;
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

  -- Preserve the established lock order: Report -> Worker profile -> User.
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

  SELECT wp.id, wp.strike_count
    INTO v_profile_id, v_old_strike_count
  FROM public.worker_profiles AS wp
  WHERE wp.user_id = v_worker_id
  FOR UPDATE;

  IF NOT FOUND OR v_old_strike_count >= 3 THEN
    RAISE EXCEPTION 'this report is not available for no-show discipline'
      USING ERRCODE = 'SM409';
  END IF;

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
  v_disciplinary_outcome := CASE
    WHEN v_new_strike_count = 3 AND v_was_active THEN 'account_suspended'
    ELSE 'no_show_strike'
  END;

  UPDATE public.worker_profiles AS wp
     SET strike_count = v_new_strike_count
   WHERE wp.id = v_profile_id;

  UPDATE public.reports AS r
     SET status = 'resolved',
         admin_response = v_response,
         reviewed_by = v_caller,
         reviewed_at = now(),
         disciplinary_outcome = v_disciplinary_outcome
   WHERE r.id = p_report_id;

  IF v_new_strike_count = 3 AND v_was_active THEN
    UPDATE public.users AS u
       SET is_active = false
     WHERE u.id = v_worker_id;
    v_suspended := true;
    v_is_active := false;
  ELSE
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
  'FT-05 #11 plus V5 durable outcome: active-Administrator-only no-show discipline. Inputs remain Report id and bounded response only. Successful 0->1 and 1->2 strikes write reports.disciplinary_outcome=no_show_strike. An actual active true->false 2->3 transition writes account_suspended; an already-inactive 2->3 result remains no_show_strike. Ordinary review_report never writes the marker.';

ALTER FUNCTION public.resolve_no_show_report_with_strike(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.resolve_no_show_report_with_strike(uuid,text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_no_show_report_with_strike(uuid,text)
  TO authenticated;
