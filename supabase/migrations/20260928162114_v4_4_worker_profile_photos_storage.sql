-- ============================================================
-- V4-4: PRIVATE WORKER PROFILE PHOTOS STORAGE
-- ============================================================
--
-- Adds one private Storage bucket and narrowly scoped object policies
-- for the single canonical extensionless object key:
--
--   <worker-user-uuid>/avatar
--
-- Active Workers may SELECT, INSERT, and DELETE only their own key.
-- An active Client may SELECT only the exact assigned Worker's key
-- while their authoritative Booking is confirmed. Replacement is an
-- application delete-then-upload flow; object UPDATE is not granted.
--
-- This migration adds no application table, column, RPC, matching
-- behavior, public read, anonymous read, or Administrator privilege.
-- It does not reuse the private worker-identity bucket.
-- ============================================================


-- ---------- 1. PRIVATE WORKER PROFILE PHOTOS BUCKET ----------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'worker-profile-photos'
       OR name = 'worker-profile-photos'
  ) THEN
    RAISE EXCEPTION
      'V4-4: unexpected pre-existing worker-profile-photos bucket';
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
  'worker-profile-photos',
  'worker-profile-photos',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
);


-- ---------- 2. ACTIVE WORKER OWNER POLICIES ----------
--
-- storage.foldername(name) excludes the filename. Exactly one folder
-- plus the fixed filename proves the canonical path shape. The path
-- segment is compared as text to authoritative UUIDs converted to
-- text; attacker-controlled text is never cast to uuid. Storage owner
-- metadata is deliberately not an authorization predicate.

CREATE POLICY "Active workers can select own profile photo"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'worker-profile-photos'
    AND cardinality(storage.foldername(name)) = 1
    AND storage.filename(name) = 'avatar'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
    AND private.is_active_worker()
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      WHERE wp.user_id = (SELECT auth.uid())
        AND wp.user_id::text = (storage.foldername(name))[1]
    )
  );

CREATE POLICY "Active workers can upload own profile photo"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'worker-profile-photos'
    AND cardinality(storage.foldername(name)) = 1
    AND storage.filename(name) = 'avatar'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
    AND private.is_active_worker()
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      WHERE wp.user_id = (SELECT auth.uid())
        AND wp.user_id::text = (storage.foldername(name))[1]
    )
  );

CREATE POLICY "Active workers can delete own profile photo"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'worker-profile-photos'
    AND cardinality(storage.foldername(name)) = 1
    AND storage.filename(name) = 'avatar'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
    AND private.is_active_worker()
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      WHERE wp.user_id = (SELECT auth.uid())
        AND wp.user_id::text = (storage.foldername(name))[1]
    )
  );


-- ---------- 3. ACTIVE CLIENT CONFIRMED-COUNTERPART SELECT ----------
--
-- The Worker profile supplies the authoritative user identity for the
-- first path segment. A Booking must independently bind that Worker to
-- the active Client and must currently be confirmed. Pending and every
-- terminal state confer no access. Clients receive no object writes.

CREATE POLICY "Confirmed clients can select assigned worker profile photo"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'worker-profile-photos'
    AND cardinality(storage.foldername(name)) = 1
    AND storage.filename(name) = 'avatar'
    AND private.is_active_client()
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      JOIN public.bookings AS b
        ON b.worker_id = wp.user_id
       AND b.client_id = (SELECT auth.uid())
       AND b.status = 'confirmed'
      WHERE wp.user_id::text = (storage.foldername(name))[1]
    )
  );
