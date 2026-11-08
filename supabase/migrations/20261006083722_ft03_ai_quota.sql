-- Recovered 2026-11-06 into the repository: applied to hosted on 2026-10-06 but missing here.
-- The statements below are the hosted supabase_migrations record, unchanged.
-- FT-03: private infrastructure only; no application ERD/history/content table.
CREATE TABLE private.ai_usage_counters (
  scope_key text PRIMARY KEY CHECK(scope_key='global' OR scope_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  minute_start timestamptz NOT NULL,
  minute_used integer NOT NULL DEFAULT 0 CHECK(minute_used>=0),
  day_start date NOT NULL,
  day_used integer NOT NULL DEFAULT 0 CHECK(day_used>=0),
  lease_id uuid,
  lease_until timestamptz,
  updated_at timestamptz NOT NULL,
  CHECK((lease_id IS NULL)=(lease_until IS NULL)),
  CHECK(scope_key<>'global' OR lease_id IS NULL)
);
ALTER TABLE private.ai_usage_counters OWNER TO postgres;
ALTER TABLE private.ai_usage_counters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.ai_usage_counters FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON TABLE private.ai_usage_counters IS 'Private bounded AI request counters/30-second leases only; never prompts, images, catalog or model output.';

CREATE FUNCTION public.reserve_ai_request(p_user_id uuid,p_mode text)
RETURNS TABLE(allowed boolean,retry_after_seconds integer,lease_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  v_role text; v_active boolean; v_now timestamptz; v_minute timestamptz;
  v_day date; v_next_day timestamptz; v_global private.ai_usage_counters%ROWTYPE;
  v_user private.ai_usage_counters%ROWTYPE; v_gm integer; v_gd integer;
  v_um integer; v_ud integer; v_lease uuid; v_retry integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE='42501';
  END IF;
  SELECT u.role,u.is_active INTO v_role,v_active FROM public.users u WHERE u.id=p_user_id FOR SHARE;
  IF NOT FOUND OR v_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE='42501';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('job_skill_suggestions','skill_gap_guidance') THEN
    RAISE EXCEPTION 'Invalid mode' USING ERRCODE='22023';
  END IF;
  IF (p_mode='job_skill_suggestions' AND v_role<>'client') OR
     (p_mode='skill_gap_guidance' AND v_role<>'worker') THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE='42501';
  END IF;

  -- One fixed lock order, global then account, serializes concurrent first
  -- reservations and all launches. No network operation occurs in this lock.
  v_now := clock_timestamp();
  INSERT INTO private.ai_usage_counters(scope_key,minute_start,day_start,updated_at)
  VALUES('global',date_trunc('minute',v_now),(v_now AT TIME ZONE 'Asia/Manila')::date,v_now)
  ON CONFLICT(scope_key) DO NOTHING;
  SELECT * INTO v_global FROM private.ai_usage_counters c WHERE c.scope_key='global' FOR UPDATE;
  -- Clock is read AFTER contention, so waited requests use the actual bucket.
  v_now := clock_timestamp(); v_minute := date_trunc('minute',v_now);
  v_day := (v_now AT TIME ZONE 'Asia/Manila')::date;
  v_next_day := (v_day+1)::timestamp AT TIME ZONE 'Asia/Manila';
  INSERT INTO private.ai_usage_counters(scope_key,minute_start,day_start,updated_at)
  VALUES(p_user_id::text,v_minute,v_day,v_now) ON CONFLICT(scope_key) DO NOTHING;
  SELECT * INTO v_user FROM private.ai_usage_counters c WHERE c.scope_key=p_user_id::text FOR UPDATE;
  v_gm := CASE WHEN v_global.minute_start=v_minute THEN v_global.minute_used ELSE 0 END;
  v_gd := CASE WHEN v_global.day_start=v_day THEN v_global.day_used ELSE 0 END;
  v_um := CASE WHEN v_user.minute_start=v_minute THEN v_user.minute_used ELSE 0 END;
  v_ud := CASE WHEN v_user.day_start=v_day THEN v_user.day_used ELSE 0 END;

  -- Account limits are combined across external modes: classification gets at
  -- most 3/fixed UTC minute and 20/Manila day; gap consumes the same allowance.
  IF v_ud>=20 OR v_gd>=100 THEN
    v_retry := greatest(1,least(86400,ceil(extract(epoch FROM v_next_day-v_now))::integer));
  ELSIF v_um>=3 OR v_gm>=10 THEN
    v_retry := greatest(1,least(60,ceil(extract(epoch FROM v_minute+interval '1 minute'-v_now))::integer));
  ELSIF v_user.lease_until>v_now THEN
    v_retry := greatest(1,least(30,ceil(extract(epoch FROM v_user.lease_until-v_now))::integer));
  END IF;
  IF v_retry IS NOT NULL THEN
    RETURN QUERY SELECT false,v_retry,NULL::uuid; RETURN;
  END IF;

  v_lease := gen_random_uuid();
  UPDATE private.ai_usage_counters c SET minute_start=v_minute,minute_used=v_gm+1,
    day_start=v_day,day_used=v_gd+1,updated_at=v_now WHERE c.scope_key='global';
  UPDATE private.ai_usage_counters c SET minute_start=v_minute,minute_used=v_um+1,
    day_start=v_day,day_used=v_ud+1,lease_id=v_lease,lease_until=v_now+interval '30 seconds',updated_at=v_now
    WHERE c.scope_key=p_user_id::text;
  -- At most 200 stale account rows per allowed reservation, under global lock.
  -- Current rows overwrite buckets; no request history is accumulated.
  DELETE FROM private.ai_usage_counters c WHERE c.scope_key IN (
    SELECT old.scope_key FROM private.ai_usage_counters old
    WHERE old.scope_key<>'global' AND old.updated_at<v_now-interval '48 hours'
      AND (old.lease_until IS NULL OR old.lease_until<v_now)
    ORDER BY old.updated_at,old.scope_key LIMIT 200);
  RETURN QUERY SELECT true,0,v_lease;
END $$;
ALTER FUNCTION public.reserve_ai_request(uuid,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reserve_ai_request(uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_ai_request(uuid,text) TO service_role;

CREATE FUNCTION public.release_ai_request(p_user_id uuid,p_lease_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$ BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE='42501';
  END IF;
  IF p_user_id IS NULL OR p_lease_id IS NULL THEN
    RAISE EXCEPTION 'Invalid lease' USING ERRCODE='22023';
  END IF;
  -- An old finalizer cannot clear a successor's lease. Never decrement usage.
  UPDATE private.ai_usage_counters c SET lease_id=NULL,lease_until=NULL
  WHERE c.scope_key=p_user_id::text AND c.lease_id=p_lease_id;
END $$;
ALTER FUNCTION public.release_ai_request(uuid,uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.release_ai_request(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.release_ai_request(uuid,uuid) TO service_role;

