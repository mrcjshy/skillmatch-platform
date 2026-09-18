-- ============================================================
-- V3-DB-02: PRIVATE WORKER VALID-ID STORAGE
-- ============================================================
--
-- SCOPE
-- -----
-- Worker ID document metadata in private.worker_id_documents plus a
-- private Storage bucket `worker-identity`.
--
-- Allowed id_type values (locked V3-1 shortlist):
--   national_id | drivers_license | passport | umid | postal_id
--
-- Path convention:
--   {worker_profiles.id}/{submission_id}.jpg|jpeg|png|webp
--
-- RPCs:
--   public.submit_my_valid_id(p_id_type, p_storage_path)
--   public.get_my_identity_submission()
--
-- is_verified is NOT written here. Upload is not approval.
--
-- D-001: no new public table.
-- ============================================================


-- ---------- 1. PRIVATE METADATA ----------

CREATE TABLE private.worker_id_documents (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_profile_id   uuid NOT NULL
                      REFERENCES public.worker_profiles(id) ON DELETE CASCADE,
  user_id             uuid NOT NULL
                      REFERENCES public.users(id) ON DELETE CASCADE,
  id_type             text NOT NULL,
  storage_path        text NOT NULL,
  status              text NOT NULL,
  rejection_reason    text,
  submitted_at        timestamptz NOT NULL DEFAULT now(),
  reviewed_at         timestamptz,
  reviewed_by         uuid REFERENCES public.users(id),
  CONSTRAINT worker_id_documents_id_type_chk
    CHECK (id_type = ANY (ARRAY[
      'national_id'::text,
      'drivers_license'::text,
      'passport'::text,
      'umid'::text,
      'postal_id'::text
    ])),
  CONSTRAINT worker_id_documents_status_chk
    CHECK (status = ANY (ARRAY[
      'pending'::text,
      'approved'::text,
      'rejected'::text,
      'superseded'::text
    ])),
  CONSTRAINT worker_id_documents_storage_path_key UNIQUE (storage_path),
  CONSTRAINT worker_id_documents_rejection_reason_chk
    CHECK (
      rejection_reason IS NULL
      OR (char_length(btrim(rejection_reason)) >= 1
          AND char_length(rejection_reason) <= 500)
    )
);

CREATE INDEX worker_id_documents_user_id_submitted_idx
  ON private.worker_id_documents (user_id, submitted_at DESC);

CREATE UNIQUE INDEX worker_id_documents_one_pending_per_user
  ON private.worker_id_documents (user_id)
  WHERE status = 'pending';

ALTER TABLE private.worker_id_documents OWNER TO postgres;

COMMENT ON TABLE private.worker_id_documents IS
  'V3-DB2: Worker valid-ID submissions. Private; not a D-001 table. '
  'Status pending/approved/rejected/superseded. is_verified stays on '
  'worker_profiles and is written only by verify_worker.';

ALTER TABLE private.worker_id_documents ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE private.worker_id_documents FROM PUBLIC;
REVOKE ALL ON TABLE private.worker_id_documents FROM anon;
REVOKE ALL ON TABLE private.worker_id_documents FROM authenticated;
REVOKE ALL ON TABLE private.worker_id_documents FROM service_role;


-- ---------- 2. PRIVATE BUCKET ----------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'worker-identity'
       OR name = 'worker-identity'
  ) THEN
    RAISE EXCEPTION
      'V3-DB2: unexpected pre-existing worker-identity bucket';
  END IF;
END
$$;

INSERT INTO storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
) VALUES (
  'worker-identity',
  'worker-identity',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
);


-- ---------- 3. PATH HELPERS ----------

CREATE FUNCTION private.worker_identity_path_is_canonical(
  p_profile_id uuid,
  p_storage_path text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT
    p_profile_id IS NOT NULL
    AND p_storage_path IS NOT NULL
    AND p_storage_path ~ (
      '^' || p_profile_id::text
      || '/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
      || '\.(jpg|jpeg|png|webp)$'
    );
$$;

ALTER FUNCTION private.worker_identity_path_is_canonical(uuid, text)
  OWNER TO postgres;

REVOKE ALL ON FUNCTION private.worker_identity_path_is_canonical(uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;


-- ---------- 4. STORAGE POLICIES ----------
--
-- One folder (worker_profiles.id) + filename. users.id is never the
-- first folder. No public URL. No Client access. Other Workers denied.

CREATE POLICY "Workers can select own identity objects"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'worker-identity'
    AND cardinality(storage.foldername(name)) = 1
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      WHERE wp.user_id = auth.uid()
        AND wp.id::text = (storage.foldername(name))[1]
    )
  );

CREATE POLICY "Workers can upload own identity objects"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'worker-identity'
    AND cardinality(storage.foldername(name)) = 1
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      WHERE wp.user_id = auth.uid()
        AND wp.id::text = (storage.foldername(name))[1]
    )
  );


-- ---------- 5. submit_my_valid_id ----------

CREATE FUNCTION public.submit_my_valid_id(
  p_id_type text,
  p_storage_path text
)
RETURNS TABLE (
  id             uuid,
  id_type        text,
  storage_path   text,
  status         text,
  submitted_at   timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller     uuid := auth.uid();
  v_profile_id uuid;
  v_role       text;
  v_type       text;
  v_path       text;
  v_id         uuid;
BEGIN
  IF v_caller IS NULL OR NOT private.is_active_worker() THEN
    RAISE EXCEPTION 'not authorized to submit a valid id'
      USING ERRCODE = '42501';
  END IF;

  SELECT wp.id, u.role
    INTO v_profile_id, v_role
  FROM public.worker_profiles AS wp
  JOIN public.users AS u ON u.id = wp.user_id
  WHERE wp.user_id = v_caller
  FOR UPDATE OF wp;

  IF NOT FOUND OR v_role IS DISTINCT FROM 'worker' THEN
    RAISE EXCEPTION 'not authorized to submit a valid id'
      USING ERRCODE = '42501';
  END IF;

  v_type := btrim(coalesce(p_id_type, ''));
  IF v_type NOT IN ('national_id', 'drivers_license', 'passport', 'umid', 'postal_id') THEN
    RAISE EXCEPTION 'invalid identity document type'
      USING ERRCODE = '22023';
  END IF;

  v_path := btrim(coalesce(p_storage_path, ''));
  IF NOT private.worker_identity_path_is_canonical(v_profile_id, v_path) THEN
    RAISE EXCEPTION 'invalid identity document path'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage.objects AS obj
    WHERE obj.bucket_id = 'worker-identity'
      AND obj.name = v_path
  ) THEN
    RAISE EXCEPTION 'invalid identity document path'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM private.worker_id_documents AS d
    WHERE d.user_id = v_caller
      AND d.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'this identity submission is not available'
      USING ERRCODE = 'SM409';
  END IF;

  UPDATE private.worker_id_documents AS d
  SET status = 'superseded'
  WHERE d.user_id = v_caller
    AND d.status IN ('pending', 'rejected');

  INSERT INTO private.worker_id_documents (
    worker_profile_id,
    user_id,
    id_type,
    storage_path,
    status
  ) VALUES (
    v_profile_id,
    v_caller,
    v_type,
    v_path,
    'pending'
  )
  RETURNING private.worker_id_documents.id INTO v_id;

  RETURN QUERY
  SELECT
    d.id,
    d.id_type,
    d.storage_path,
    d.status,
    d.submitted_at
  FROM private.worker_id_documents AS d
  WHERE d.id = v_id;
END;
$$;

ALTER FUNCTION public.submit_my_valid_id(text, text) OWNER TO postgres;

COMMENT ON FUNCTION public.submit_my_valid_id(text, text) IS
  'V3-DB2: Worker submits own valid-ID object path. Does not set '
  'is_verified. Approved Workers cannot replace a live submission.';

REVOKE ALL ON FUNCTION public.submit_my_valid_id(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_my_valid_id(text, text) FROM anon;
REVOKE ALL ON FUNCTION public.submit_my_valid_id(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.submit_my_valid_id(text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.submit_my_valid_id(text, text) TO authenticated;


-- ---------- 6. get_my_identity_submission ----------

CREATE FUNCTION public.get_my_identity_submission()
RETURNS TABLE (
  id                 uuid,
  id_type            text,
  storage_path       text,
  status             text,
  rejection_reason   text,
  submitted_at       timestamptz,
  reviewed_at        timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authorized to read identity submission'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    d.id,
    d.id_type,
    d.storage_path,
    d.status,
    CASE WHEN d.status = 'rejected' THEN d.rejection_reason ELSE NULL END,
    d.submitted_at,
    d.reviewed_at
  FROM private.worker_id_documents AS d
  WHERE d.user_id = v_caller
    AND d.status IN ('pending', 'approved', 'rejected')
  ORDER BY d.submitted_at DESC, d.id DESC
  LIMIT 1;
END;
$$;

ALTER FUNCTION public.get_my_identity_submission() OWNER TO postgres;

COMMENT ON FUNCTION public.get_my_identity_submission() IS
  'V3-DB2: caller''s current (non-superseded) ID submission. Zero rows '
  'if none. Rejection reason is returned only for rejected status.';

REVOKE ALL ON FUNCTION public.get_my_identity_submission() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_identity_submission() FROM anon;
REVOKE ALL ON FUNCTION public.get_my_identity_submission() FROM authenticated;
REVOKE ALL ON FUNCTION public.get_my_identity_submission() FROM service_role;
GRANT EXECUTE ON FUNCTION public.get_my_identity_submission() TO authenticated;
