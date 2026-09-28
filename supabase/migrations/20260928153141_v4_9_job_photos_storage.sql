-- ============================================================
-- V4-9: OPTIONAL PRIVATE JOB PHOTOS STORAGE
-- ============================================================
--
-- Adds one private Storage bucket and narrowly scoped object policies
-- for the canonical extensionless object key:
--
--   <client_uuid>/<job_uuid>/<1|2|3>
--
-- The authoritative Job and Booking relationships establish access.
-- Path text and Storage owner metadata never establish ownership.
-- No application table, Job-photo column, matching change, public
-- read, Administrator access, or object UPDATE policy is introduced.
-- ============================================================


-- ---------- 1. PRIVATE JOB-PHOTOS BUCKET ----------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'job-photos'
       OR name = 'job-photos'
  ) THEN
    RAISE EXCEPTION
      'V4-9: unexpected pre-existing job-photos bucket';
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
  'job-photos',
  'job-photos',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
);


-- ---------- 2. ACTIVE CLIENT INSERT: OWN OPEN JOB ----------
--
-- storage.foldername(name) excludes the filename, so cardinality 2
-- proves that the key has exactly the Client and Job folders. Every
-- attacker-controlled path segment is compared as text to an
-- authoritative UUID converted to text; malformed path text is never
-- cast to uuid. The fixed filename allowlist bounds each Job to three
-- immutable slots. Replacement is unavailable because no UPDATE
-- policy is created.

CREATE POLICY "Active clients can upload own open job photos"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'job-photos'
    AND cardinality(storage.foldername(name)) = 2
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
    AND storage.filename(name) IN ('1', '2', '3')
    AND private.is_active_client()
    AND EXISTS (
      SELECT 1
      FROM public.job_postings AS jp
      WHERE jp.client_id = (SELECT auth.uid())
        AND jp.client_id::text = (storage.foldername(name))[1]
        AND jp.id::text = (storage.foldername(name))[2]
        AND jp.status = 'open'
    )
  );


-- ---------- 3. ACTIVE CLIENT SELECT: OWN EXISTING JOB ----------

CREATE POLICY "Active clients can select own job photos"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'job-photos'
    AND cardinality(storage.foldername(name)) = 2
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
    AND storage.filename(name) IN ('1', '2', '3')
    AND private.is_active_client()
    AND EXISTS (
      SELECT 1
      FROM public.job_postings AS jp
      WHERE jp.client_id = (SELECT auth.uid())
        AND jp.client_id::text = (storage.foldername(name))[1]
        AND jp.id::text = (storage.foldername(name))[2]
    )
  );


-- ---------- 4. ACTIVE WORKER SELECT: CONFIRMED ASSIGNMENT ----------
--
-- The Job supplies the canonical path association. A Booking must
-- independently bind that same Job and Client to the active Worker,
-- and must currently be confirmed. Match eligibility and pending or
-- terminal Bookings confer no object access.

CREATE POLICY "Confirmed assigned workers can select job photos"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'job-photos'
    AND cardinality(storage.foldername(name)) = 2
    AND storage.filename(name) IN ('1', '2', '3')
    AND private.is_active_worker()
    AND EXISTS (
      SELECT 1
      FROM public.job_postings AS jp
      JOIN public.bookings AS b
        ON b.job_id = jp.id
       AND b.client_id = jp.client_id
      WHERE jp.client_id::text = (storage.foldername(name))[1]
        AND jp.id::text = (storage.foldername(name))[2]
        AND b.worker_id = (SELECT auth.uid())
        AND b.status = 'confirmed'
    )
  );


-- ---------- 5. ACTIVE CLIENT DELETE: OWN OPEN JOB ----------
--
-- Supports objects-first cleanup while an owned Job remains open.
-- Workers receive no DELETE authority.

CREATE POLICY "Active clients can delete own open job photos"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'job-photos'
    AND cardinality(storage.foldername(name)) = 2
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
    AND storage.filename(name) IN ('1', '2', '3')
    AND private.is_active_client()
    AND EXISTS (
      SELECT 1
      FROM public.job_postings AS jp
      WHERE jp.client_id = (SELECT auth.uid())
        AND jp.client_id::text = (storage.foldername(name))[1]
        AND jp.id::text = (storage.foldername(name))[2]
        AND jp.status = 'open'
    )
  );
