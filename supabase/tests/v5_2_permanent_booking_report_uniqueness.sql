-- V5-2 structural regression. Run after migrations are applied.
BEGIN;

DO $$
DECLARE
  v_definition text;
  v_old_exists boolean;
BEGIN
  SELECT pg_get_indexdef(i.indexrelid)
    INTO v_definition
  FROM pg_index AS i
  JOIN pg_class AS c ON c.oid = i.indexrelid
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'reports_one_counterpart_per_reporter_booking';

  IF v_definition IS NULL
     OR v_definition NOT LIKE '%UNIQUE INDEX%'
     OR v_definition NOT LIKE '%(reporter_id, booking_id)%'
     OR v_definition NOT LIKE '%WHERE (booking_id IS NOT NULL)%'
     OR v_definition LIKE '%status%' THEN
    RAISE EXCEPTION 'V5-2 permanent report uniqueness index is incorrect: %',
      coalesce(v_definition, 'missing');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'reports_one_active_counterpart_per_reporter_booking'
  ) INTO v_old_exists;

  IF v_old_exists THEN
    RAISE EXCEPTION 'R3 active-only report uniqueness index still exists';
  END IF;
END;
$$;

ROLLBACK;
