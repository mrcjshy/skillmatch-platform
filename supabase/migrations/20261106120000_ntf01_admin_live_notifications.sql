-- ============================================================
-- NTF-01: ADMINISTRATOR ALERTS FOR ID SUBMISSIONS AND NEW ACCOUNTS
-- ============================================================
--
-- SCOPE
-- -----
-- Owner request 2026-11-06: Administrators get a live alert when a Worker
-- submits an ID that needs verification and when a new Worker or Client
-- account is created. Reports already alert Administrators
-- (submit_my_booking_report, submit_my_app_issue) and are unchanged.
--
-- Each alert is an ordinary notifications row for every ACTIVE
-- Administrator, so the existing R5 broadcast (live in-app refresh) and
-- R5B push dispatch triggers deliver it with no further change.
--
--   identity_submitted  'A Worker submitted an ID for review.'
--                       after a 'pending' private.worker_id_documents row
--                       is inserted (first submission or resubmission)
--   worker_registered   'A new Worker account was created.'
--   client_registered   'A new Client account was created.'
--                       after a public.users row with that role is inserted
--
-- Messages carry no names, because pushes pass through the Expo push
-- service. Installed builds show unknown types as a neutral "Notification"
-- and the push title falls back to "SkillMatch", so nothing breaks.
--
-- Fail open: an alert that cannot be written raises a WARNING and never
-- blocks the registration or the ID submission (same rule as R5B).
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No table, column, RLS or grant change on user data.
--   * No change to submit_my_valid_id, the report functions or R5/R5B.
-- ============================================================


-- ---------- 1. NOTIFICATION TYPES ----------

ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (
  (type)::text = ANY (ARRAY[
    'booking_request', 'booking_confirmed', 'booking_cancelled', 'booking_completed',
    'no_show_strike', 'account_suspended', 'account_reinstated', 'payment_received',
    'worker_verified', 'report_submitted',
    'identity_submitted', 'worker_registered', 'client_registered'
  ]::text[])
);


-- ---------- 2. ALERT EVERY ACTIVE ADMINISTRATOR ----------

CREATE OR REPLACE FUNCTION private.ntf01_notify_active_admins(p_type text, p_message text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_admin uuid;
BEGIN
  FOR v_admin IN
    SELECT u.id FROM public.users AS u
     WHERE u.role = 'administrator' AND u.is_active = true
     ORDER BY u.id
  LOOP
    PERFORM private.emit_notification(v_admin, p_type, p_message);
  END LOOP;
END;
$$;


-- ---------- 3. TRIGGERS ----------

CREATE OR REPLACE FUNCTION private.ntf01_notify_identity_submitted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  BEGIN
    PERFORM private.ntf01_notify_active_admins('identity_submitted', 'A Worker submitted an ID for review.');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'NTF-01 identity alert skipped';
  END;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION private.ntf01_notify_account_registered()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  BEGIN
    IF NEW.role = 'worker' THEN
      PERFORM private.ntf01_notify_active_admins('worker_registered', 'A new Worker account was created.');
    ELSIF NEW.role = 'client' THEN
      PERFORM private.ntf01_notify_active_admins('client_registered', 'A new Client account was created.');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'NTF-01 registration alert skipped';
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS ntf01_identity_submitted ON private.worker_id_documents;
CREATE TRIGGER ntf01_identity_submitted
  AFTER INSERT ON private.worker_id_documents
  FOR EACH ROW
  WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION private.ntf01_notify_identity_submitted();

DROP TRIGGER IF EXISTS ntf01_account_registered ON public.users;
CREATE TRIGGER ntf01_account_registered
  AFTER INSERT ON public.users
  FOR EACH ROW
  WHEN (NEW.role IN ('worker', 'client'))
  EXECUTE FUNCTION private.ntf01_notify_account_registered();


-- ---------- 4. OWNERSHIP AND GRANTS ----------

ALTER FUNCTION private.ntf01_notify_active_admins(text, text) OWNER TO postgres;
ALTER FUNCTION private.ntf01_notify_identity_submitted() OWNER TO postgres;
ALTER FUNCTION private.ntf01_notify_account_registered() OWNER TO postgres;

REVOKE ALL ON FUNCTION private.ntf01_notify_active_admins(text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.ntf01_notify_identity_submitted() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.ntf01_notify_account_registered() FROM PUBLIC, anon, authenticated, service_role;
