-- V5-2: one counterpart report ever per participant per Booking.
-- The Phase-0 census found no historical duplicate (reporter_id, booking_id)
-- pairs, so this forward-only replacement preserves every report row.

DROP INDEX public.reports_one_active_counterpart_per_reporter_booking;

CREATE UNIQUE INDEX reports_one_counterpart_per_reporter_booking
  ON public.reports (reporter_id, booking_id)
  WHERE booking_id IS NOT NULL;

COMMENT ON INDEX public.reports_one_counterpart_per_reporter_booking IS
  'V5-2: at most one Booking-bound counterpart report ever per '
  '(reporter_id, booking_id), independent of report status. NULL Booking '
  'app_issue reports remain repeatable.';
