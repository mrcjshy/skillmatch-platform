-- ============================================================
-- R5D-CLIENT-B1: CONFIRMED-BOOKING CLIENT PORTFOLIO READ
-- ============================================================
--
-- SCOPE
-- -----
-- Lets an active authenticated Client SELECT the assigned Worker's
-- portfolio text, image metadata, and exact private Storage objects
-- only while they share a confirmed Booking with that Worker.
--
-- This migration:
--   1. drops the residual authenticated-wide portfolio_items SELECT
--   2. adds one Client SELECT policy on public.portfolio_items
--   3. adds one Client SELECT policy on public.portfolio_item_images
--   4. adds one Client SELECT policy on storage.objects for bucket
--      portfolio, keyed to exact portfolio_item_images.storage_path
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No public RPC.
--   * No new helper function.
--   * No Client INSERT / UPDATE / DELETE on portfolio tables or
--     Storage objects.
--   * No Admin special write path.
--   * No grant widening.
--   * No bucket update (portfolio remains private, 5 MiB, JPEG/PNG/WebP).
--   * No matching, ranking, eligibility, verification, or rating change.
--   * No pre-booking / match-results portfolio access.
--   * No terminal-state (pending/completed/cancelled/no_show) access.
--   * No change to Worker-own SELECT / INSERT / UPDATE / DELETE.
-- ============================================================


-- ---------- 1. DROP RESIDUAL BROAD TEXT SELECT ----------

DROP POLICY "Anyone authenticated can read portfolio items"
  ON public.portfolio_items;


-- ---------- 2. CLIENT SELECT: portfolio_items ----------
--
-- Row is visible only when the caller is an active Client and the
-- item's worker_profiles.user_id is bookings.worker_id on a confirmed
-- Booking the caller owns. Another Worker's items stay invisible.

CREATE POLICY "Clients can select confirmed counterpart portfolio items"
  ON public.portfolio_items
  FOR SELECT
  TO authenticated
  USING (
    private.is_active_client()
    AND EXISTS (
      SELECT 1
      FROM public.worker_profiles AS wp
      JOIN public.bookings AS b
        ON b.worker_id = wp.user_id
       AND b.client_id = auth.uid()
       AND b.status = 'confirmed'
      WHERE wp.id = portfolio_items.worker_id
    )
  );

COMMENT ON POLICY "Clients can select confirmed counterpart portfolio items"
  ON public.portfolio_items IS
  'R5D-CLIENT-B1: active Client reads portfolio text only for the '
  'Worker assigned on the Client''s own confirmed Booking. No write.';


-- ---------- 3. CLIENT SELECT: portfolio_item_images ----------

CREATE POLICY "Clients can select confirmed counterpart portfolio item images"
  ON public.portfolio_item_images
  FOR SELECT
  TO authenticated
  USING (
    private.is_active_client()
    AND EXISTS (
      SELECT 1
      FROM public.portfolio_items AS pi
      JOIN public.worker_profiles AS wp
        ON wp.id = pi.worker_id
      JOIN public.bookings AS b
        ON b.worker_id = wp.user_id
       AND b.client_id = auth.uid()
       AND b.status = 'confirmed'
      WHERE pi.id = portfolio_item_images.portfolio_item_id
    )
  );

COMMENT ON POLICY "Clients can select confirmed counterpart portfolio item images"
  ON public.portfolio_item_images IS
  'R5D-CLIENT-B1: active Client reads image metadata only for a parent '
  'portfolio item owned by the Worker on the Client''s own confirmed '
  'Booking. No write.';


-- ---------- 4. CLIENT SELECT: exact portfolio Storage objects ----------
--
-- Object SELECT is metadata-backed: storage.objects.name must equal an
-- existing portfolio_item_images.storage_path. Folder-only permission
-- is intentionally not granted. Path segments are not cast to uuid.
-- No COMMENT ON POLICY: storage.objects is not owned by postgres in
-- this project (same constraint as R5D-IMG-B2).

CREATE POLICY "Clients can select confirmed counterpart portfolio objects"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'portfolio'
    AND private.is_active_client()
    AND EXISTS (
      SELECT 1
      FROM public.portfolio_item_images AS pii
      JOIN public.portfolio_items AS pi
        ON pi.id = pii.portfolio_item_id
      JOIN public.worker_profiles AS wp
        ON wp.id = pi.worker_id
      JOIN public.bookings AS b
        ON b.worker_id = wp.user_id
       AND b.client_id = auth.uid()
       AND b.status = 'confirmed'
      WHERE pii.storage_path = storage.objects.name
    )
  );
