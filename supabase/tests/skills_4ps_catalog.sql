-- 4Ps skill catalog — local SQL verification after all migrations. Read-only checks.
CREATE OR REPLACE FUNCTION pg_temp.pass(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(p_ok, false) THEN RAISE NOTICE 'PASS %', p_name; ELSE RAISE NOTICE 'FAIL % %', p_name, p_detail; END IF;
END; $$;

SELECT pg_temp.pass('30 skills', (SELECT count(*) FROM public.skills) = 30, (SELECT count(*)::text FROM public.skills));
SELECT pg_temp.pass('every skill has one of the 4 categories',
  NOT EXISTS (SELECT 1 FROM public.skills WHERE category IS NULL OR category NOT IN
    ('Home repair & construction', 'Appliance & vehicle', 'Household services', 'Care & personal services')));
SELECT pg_temp.pass('category sizes 9/5/8/8',
  (SELECT string_agg(category || '=' || n, ',' ORDER BY category) FROM
    (SELECT category, count(*) n FROM public.skills GROUP BY category) x)
  = 'Appliance & vehicle=5,Care & personal services=8,Home repair & construction=9,Household services=8',
  (SELECT string_agg(category || '=' || n, ',' ORDER BY category) FROM (SELECT category, count(*) n FROM public.skills GROUP BY category) x));
SELECT pg_temp.pass('General Labor id kept as Moving & Hauling',
  EXISTS (SELECT 1 FROM public.skills WHERE id = '90be7a80-35e1-49ba-a2c8-c4689212603f' AND skill_name = 'Moving & Hauling'));
SELECT pg_temp.pass('Aircon id kept as Aircon Cleaning & Repair',
  EXISTS (SELECT 1 FROM public.skills WHERE id = 'f2f28666-6ada-42a8-adf4-caf6e5c553c9' AND skill_name = 'Aircon Cleaning & Repair'));
SELECT pg_temp.pass('no old vague names remain',
  NOT EXISTS (SELECT 1 FROM public.skills WHERE skill_name IN ('General Labor', 'Aircon Repair', 'Laundry', 'Cooking', 'Gardening', 'Sewing')));
SELECT pg_temp.pass('new Caregiving skill present',
  EXISTS (SELECT 1 FROM public.skills WHERE id = 'd7e7d525-9d07-448a-8b79-b1f1565f39b3' AND skill_name = 'Caregiving'));
SELECT pg_temp.pass('catalog fits the AI classifier bound (<=128 rows, <=12000 bytes)',
  (SELECT count(*) <= 128 AND octet_length(json_agg(json_build_object('id', id, 'name', skill_name))::text) <= 12000 FROM public.skills));
