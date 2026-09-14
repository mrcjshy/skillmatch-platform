-- ============================================================
-- R5D-IMG-B1: PORTFOLIO ITEM IMAGE METADATA
-- ============================================================
--
-- SCOPE
-- -----
-- Adds the 13th application table public.portfolio_item_images as
-- the Josh-approved D-001 amendment for 0..5 images per portfolio
-- item. Cover image is position 1. Database authority for the
-- maximum is CHECK (position BETWEEN 1 AND 5) plus UNIQUE
-- (portfolio_item_id, position). No count trigger.
--
-- This migration:
--   1. creates public.portfolio_item_images
--   2. enables RLS and normalizes table grants
--   3. adds Worker-owned SELECT / INSERT / DELETE policies
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No Storage bucket and no storage.objects policy.
--   * No change to portfolio_items, including image_url.
--   * No Client image SELECT policy.
--   * No Admin special write path.
--   * No UPDATE grant or UPDATE policy.
--   * No helper function.
--   * No matching, badge_level, skills, or profile mutation.
--   * No cleanup of pre-existing portfolio_items anon grants.
-- ============================================================


-- ---------- 1. TABLE ----------

CREATE TABLE public.portfolio_item_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  portfolio_item_id uuid NOT NULL
    REFERENCES public.portfolio_items(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  position smallint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT portfolio_item_images_position_check
    CHECK (position BETWEEN 1 AND 5),
  CONSTRAINT portfolio_item_images_item_position_key
    UNIQUE (portfolio_item_id, position),
  CONSTRAINT portfolio_item_images_storage_path_key
    UNIQUE (storage_path)
);

ALTER TABLE public.portfolio_item_images OWNER TO postgres;

COMMENT ON TABLE public.portfolio_item_images IS
  'R5D-IMG-B1: 0..5 image metadata rows per portfolio item. '
  'Cover is position 1. Storage objects are out of this migration.';

COMMENT ON COLUMN public.portfolio_item_images.portfolio_item_id IS
  'Parent public.portfolio_items.id. Cascades on parent delete.';

COMMENT ON COLUMN public.portfolio_item_images.storage_path IS
  'Private Storage object key. Not an ownership signal.';

COMMENT ON COLUMN public.portfolio_item_images.position IS
  '1..5 in selection order. Position 1 is the cover image.';


-- ---------- 2. RLS AND DIRECT TABLE PRIVILEGES ----------
--
-- ALTER DEFAULT PRIVILEGES in the baseline grants ALL on new public
-- tables to anon, authenticated and service_role. Client roles are
-- stripped here. authenticated is granted SELECT, INSERT, and DELETE
-- only. There is no UPDATE grant and no UPDATE policy.
--
-- service_role is not given an extra explicit grant. The postgres
-- owner entry is untouched.

ALTER TABLE public.portfolio_item_images ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.portfolio_item_images FROM PUBLIC;

REVOKE ALL ON TABLE public.portfolio_item_images FROM anon;

REVOKE ALL ON TABLE public.portfolio_item_images FROM authenticated;

GRANT SELECT, INSERT, DELETE ON TABLE public.portfolio_item_images
  TO authenticated;


-- ---------- 3. WORKER OWNERSHIP POLICIES ----------
--
-- Ownership is:
--   auth.uid()
--   -> public.worker_profiles.user_id
--   -> worker_profiles.id
--   -> public.portfolio_items.worker_id
--
-- portfolio_items.worker_id is never compared to auth.uid().
-- storage_path is never an authorization predicate.

CREATE POLICY "Workers can select own portfolio item images"
  ON public.portfolio_item_images
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.portfolio_items AS pi
      JOIN public.worker_profiles AS wp
        ON wp.id = pi.worker_id
      WHERE pi.id = portfolio_item_images.portfolio_item_id
        AND wp.user_id = auth.uid()
    )
  );

CREATE POLICY "Workers can insert own portfolio item images"
  ON public.portfolio_item_images
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.portfolio_items AS pi
      JOIN public.worker_profiles AS wp
        ON wp.id = pi.worker_id
      WHERE pi.id = portfolio_item_images.portfolio_item_id
        AND wp.user_id = auth.uid()
    )
  );

CREATE POLICY "Workers can delete own portfolio item images"
  ON public.portfolio_item_images
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.portfolio_items AS pi
      JOIN public.worker_profiles AS wp
        ON wp.id = pi.worker_id
      WHERE pi.id = portfolio_item_images.portfolio_item_id
        AND wp.user_id = auth.uid()
    )
  );

COMMENT ON POLICY "Workers can select own portfolio item images"
  ON public.portfolio_item_images IS
  'R5D-IMG-B1: Worker reads image metadata only for a parent '
  'portfolio item owned by their worker_profiles.id. No Client SELECT.';

COMMENT ON POLICY "Workers can insert own portfolio item images"
  ON public.portfolio_item_images IS
  'R5D-IMG-B1: Worker inserts image metadata only for a parent '
  'portfolio item owned by their worker_profiles.id.';

COMMENT ON POLICY "Workers can delete own portfolio item images"
  ON public.portfolio_item_images IS
  'R5D-IMG-B1: Worker deletes image metadata only for a parent '
  'portfolio item owned by their worker_profiles.id.';
