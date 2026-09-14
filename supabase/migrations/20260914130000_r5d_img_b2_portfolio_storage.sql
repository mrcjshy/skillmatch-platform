-- ============================================================
-- R5D-IMG-B2: PRIVATE PORTFOLIO STORAGE + OBJECT POLICIES
-- ============================================================
--
-- SCOPE
-- -----
-- Adds the private storage.buckets row `portfolio` and Worker-own
-- storage.objects policies for the approved 0..5-image path:
--
--   <worker_profiles.id>/<portfolio_items.id>/<image_uuid>.<ext>
--
-- Cover metadata remains public.portfolio_item_images (B1).
-- This migration does not upload objects and does not change
-- application tables.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No change to portfolio_items or portfolio_item_images.
--   * No Client object SELECT.
--   * No Admin special write path.
--   * No UPDATE policy.
--   * No helper function.
--   * No matching, badge_level, skills, or profile mutation.
--   * No grant cleanup of storage.objects / storage.buckets
--     outside the portfolio policies.
--   * No ON CONFLICT overwrite of a pre-existing bucket.
-- ============================================================


-- ---------- 1. PRIVATE PORTFOLIO BUCKET ----------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'portfolio'
       OR name = 'portfolio'
  ) THEN
    RAISE EXCEPTION
      'R5D-IMG-B2: unexpected pre-existing portfolio bucket';
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
  'portfolio',
  'portfolio',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
);


-- ---------- 2. WORKER OWNERSHIP POLICIES ----------
--
-- Ownership is:
--   auth.uid()
--   -> public.worker_profiles.user_id
--   -> worker_profiles.id
--   -> public.portfolio_items.worker_id
--
-- Path folders are compared as text to those authoritative IDs.
-- users.id is never the first folder.
-- storage.objects.owner / owner_id are never predicates.
-- storage.foldername(name) excludes the filename, so a canonical
-- object has exactly two folders.

CREATE POLICY "Workers can select own portfolio objects"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'portfolio'
    AND cardinality(storage.foldername(name)) = 2
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      JOIN public.portfolio_items AS pi
        ON pi.worker_id = wp.id
      WHERE wp.user_id = auth.uid()
        AND wp.id::text = (storage.foldername(name))[1]
        AND pi.id::text = (storage.foldername(name))[2]
    )
  );

CREATE POLICY "Workers can upload own portfolio objects"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'portfolio'
    AND cardinality(storage.foldername(name)) = 2
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      JOIN public.portfolio_items AS pi
        ON pi.worker_id = wp.id
      WHERE wp.user_id = auth.uid()
        AND wp.id::text = (storage.foldername(name))[1]
        AND pi.id::text = (storage.foldername(name))[2]
    )
  );

CREATE POLICY "Workers can delete own portfolio objects"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'portfolio'
    AND cardinality(storage.foldername(name)) = 2
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      JOIN public.portfolio_items AS pi
        ON pi.worker_id = wp.id
      WHERE wp.user_id = auth.uid()
        AND wp.id::text = (storage.foldername(name))[1]
        AND pi.id::text = (storage.foldername(name))[2]
    )
  );
