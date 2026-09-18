-- ============================================================
-- V3-DB-03: WORKER ID REVIEW + APPROVE/REJECT
-- ============================================================
--
-- SCOPE
-- -----
-- Admin review of pending Worker ID submissions.
--
--   public.list_workers_pending_id_review()
--   public.get_worker_identity_for_review(p_worker_user_id)
--   public.approve_worker_identity(p_worker_user_id)
--   public.reject_worker_identity(p_worker_user_id, p_reason)
--
-- Approval calls public.verify_worker() — the sole writer of
-- is_verified / verified_by. Reject never touches those columns.
--
-- 42501 for non-admin. SM409 collapse for unavailable targets.
-- No hosted deployment.
-- ============================================================


-- ---------- 1. Admin object read helper ----------

CREATE FUNCTION private.admin_may_read_identity_object(p_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND private.is_admin()
    AND EXISTS (
      SELECT 1
      FROM private.worker_id_documents AS d
      WHERE d.storage_path = p_name
        AND d.status = 'pending'
    );
$$;

ALTER FUNCTION private.admin_may_read_identity_object(text) OWNER TO postgres;

COMMENT ON FUNCTION private.admin_may_read_identity_object(text) IS
  'V3-DB3: true when the caller is an active Administrator and p_name '
  'is the exact storage_path of a pending ID submission.';

REVOKE ALL ON FUNCTION private.admin_may_read_identity_object(text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION private.admin_may_read_identity_object(text)
  FROM anon;
REVOKE ALL ON FUNCTION private.admin_may_read_identity_object(text)
  FROM service_role;
GRANT EXECUTE ON FUNCTION private.admin_may_read_identity_object(text)
  TO authenticated;

CREATE POLICY "Admins can select pending identity objects"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'worker-identity'
    AND private.admin_may_read_identity_object(name)
  );


-- ---------- 2. Pending review queue ----------

CREATE FUNCTION public.list_workers_pending_id_review()
RETURNS TABLE (
  user_id        uuid,
  document_id    uuid,
  full_name      text,
  phone          text,
  barangay       text,
  city           text,
  id_type        text,
  submitted_at   timestamptz,
  skills         text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to list identity reviews'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    d.id,
    u.full_name,
    u.phone,
    u.barangay,
    u.city,
    d.id_type,
    d.submitted_at,
    coalesce(
      (
        SELECT array_agg(s.skill_name::text ORDER BY s.skill_name, s.id)
        FROM public.worker_skills AS ws
        JOIN public.skills AS s ON s.id = ws.skill_id
        WHERE ws.worker_id = wp.id
      ),
      '{}'::text[]
    )
  FROM private.worker_id_documents AS d
  JOIN public.worker_profiles AS wp ON wp.id = d.worker_profile_id
  JOIN public.users AS u ON u.id = d.user_id
  WHERE d.status = 'pending'
    AND u.role = 'worker'
  ORDER BY d.submitted_at ASC, d.id ASC;
END;
$$;

ALTER FUNCTION public.list_workers_pending_id_review() OWNER TO postgres;

COMMENT ON FUNCTION public.list_workers_pending_id_review() IS
  'V3-DB3: Administrator pending-ID queue. Empty is success. Non-admin '
  'callers receive 42501. Does not project email, storage_path, or verifier.';

REVOKE ALL ON FUNCTION public.list_workers_pending_id_review() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_workers_pending_id_review() FROM anon;
REVOKE ALL ON FUNCTION public.list_workers_pending_id_review() FROM authenticated;
REVOKE ALL ON FUNCTION public.list_workers_pending_id_review() FROM service_role;
GRANT EXECUTE ON FUNCTION public.list_workers_pending_id_review() TO authenticated;


-- ---------- 3. Review payload ----------

CREATE FUNCTION public.get_worker_identity_for_review(p_worker_user_id uuid)
RETURNS TABLE (
  user_id        uuid,
  document_id    uuid,
  full_name      text,
  phone          text,
  barangay       text,
  city           text,
  id_type        text,
  storage_path   text,
  submitted_at   timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to review identity documents'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    d.id,
    u.full_name,
    u.phone,
    u.barangay,
    u.city,
    d.id_type,
    d.storage_path,
    d.submitted_at
  FROM private.worker_id_documents AS d
  JOIN public.users AS u ON u.id = d.user_id
  WHERE d.user_id = p_worker_user_id
    AND d.status = 'pending'
    AND u.role = 'worker'
  ORDER BY d.submitted_at DESC, d.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'this identity submission is not available'
      USING ERRCODE = 'SM409';
  END IF;
END;
$$;

ALTER FUNCTION public.get_worker_identity_for_review(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.get_worker_identity_for_review(uuid) IS
  'V3-DB3: Administrator pending-ID review payload including exact '
  'storage_path. Missing/non-pending targets collapse to SM409.';

REVOKE ALL ON FUNCTION public.get_worker_identity_for_review(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_worker_identity_for_review(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.get_worker_identity_for_review(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.get_worker_identity_for_review(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_worker_identity_for_review(uuid) TO authenticated;


-- ---------- 4. Approve (wraps verify_worker) ----------

CREATE FUNCTION public.approve_worker_identity(p_worker_user_id uuid)
RETURNS TABLE (
  user_id      uuid,
  document_id  uuid,
  is_verified  boolean,
  verified_by  uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller     uuid := auth.uid();
  v_doc_id     uuid;
  v_status     text;
  v_verified   boolean;
  v_verified_by uuid;
BEGIN
  IF v_caller IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to approve identity documents'
      USING ERRCODE = '42501';
  END IF;

  SELECT d.id, d.status
    INTO v_doc_id, v_status
  FROM private.worker_id_documents AS d
  WHERE d.user_id = p_worker_user_id
    AND d.status = 'pending'
  FOR UPDATE;

  IF NOT FOUND OR v_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'this identity submission is not available'
      USING ERRCODE = 'SM409';
  END IF;

  SELECT vw.user_id, vw.is_verified, vw.verified_by
    INTO p_worker_user_id, v_verified, v_verified_by
  FROM public.verify_worker(p_worker_user_id) AS vw;

  UPDATE private.worker_id_documents AS d
  SET status = 'approved',
      reviewed_at = clock_timestamp(),
      reviewed_by = v_caller,
      rejection_reason = NULL
  WHERE d.id = v_doc_id;

  RETURN QUERY
  SELECT p_worker_user_id, v_doc_id, v_verified, v_verified_by;
END;
$$;

ALTER FUNCTION public.approve_worker_identity(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.approve_worker_identity(uuid) IS
  'V3-DB3: Administrator approves a pending ID by calling verify_worker, '
  'then marks the submission approved. is_verified is not written here.';

REVOKE ALL ON FUNCTION public.approve_worker_identity(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_worker_identity(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.approve_worker_identity(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.approve_worker_identity(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.approve_worker_identity(uuid) TO authenticated;


-- ---------- 5. Reject ----------

CREATE FUNCTION public.reject_worker_identity(
  p_worker_user_id uuid,
  p_reason text
)
RETURNS TABLE (
  user_id            uuid,
  document_id        uuid,
  status             text,
  rejection_reason   text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller uuid := auth.uid();
  v_doc_id uuid;
  v_reason text;
  v_verified boolean;
BEGIN
  IF v_caller IS NULL OR NOT private.is_admin() THEN
    RAISE EXCEPTION 'not authorized to reject identity documents'
      USING ERRCODE = '42501';
  END IF;

  v_reason := btrim(coalesce(p_reason, ''));
  IF char_length(v_reason) < 1 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'invalid rejection reason'
      USING ERRCODE = '22023';
  END IF;

  SELECT d.id
    INTO v_doc_id
  FROM private.worker_id_documents AS d
  WHERE d.user_id = p_worker_user_id
    AND d.status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'this identity submission is not available'
      USING ERRCODE = 'SM409';
  END IF;

  SELECT wp.is_verified
    INTO v_verified
  FROM public.worker_profiles AS wp
  WHERE wp.user_id = p_worker_user_id;

  UPDATE private.worker_id_documents AS d
  SET status = 'rejected',
      rejection_reason = v_reason,
      reviewed_at = clock_timestamp(),
      reviewed_by = v_caller
  WHERE d.id = v_doc_id;

  RETURN QUERY
  SELECT p_worker_user_id, v_doc_id, 'rejected'::text, v_reason;

  -- Guard: reject must not have flipped verification.
  IF EXISTS (
    SELECT 1
    FROM public.worker_profiles AS wp
    WHERE wp.user_id = p_worker_user_id
      AND wp.is_verified IS DISTINCT FROM v_verified
  ) THEN
    RAISE EXCEPTION 'identity rejection must not change verification'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

ALTER FUNCTION public.reject_worker_identity(uuid, text) OWNER TO postgres;

COMMENT ON FUNCTION public.reject_worker_identity(uuid, text) IS
  'V3-DB3: Administrator rejects a pending ID. is_verified is unchanged.';

REVOKE ALL ON FUNCTION public.reject_worker_identity(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_worker_identity(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.reject_worker_identity(uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.reject_worker_identity(uuid, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.reject_worker_identity(uuid, text) TO authenticated;
