-- 4Ps skill catalog (owner request 2026-11-05).
--
-- SkillMatch serves Pantawid Pamilyang Pilipino Program (4Ps) households in Barangay Santa Ana,
-- Pateros. The catalog moves from 16 to 30 blue-collar and service skills modelled on the
-- TESDA NC II trades used in DSWD-TESDA Sustainable Livelihood training, with four categories.
--
--   * Every existing skill id is kept, so no worker_skills or job_skills row changes meaning.
--   * Six vague or overlapping names are clarified in place (General Labor -> Moving & Hauling,
--     Aircon Repair -> Aircon Cleaning & Repair, Laundry -> Laundry & Ironing,
--     Cooking -> Cooking & Food Prep, Gardening -> Gardening & Landscaping,
--     Sewing -> Sewing & Dressmaking).
--   * Fourteen skills are added with fixed ids.
--   * Fails closed: the current catalog must be exactly the approved 16 id+name pairs.
-- No schema, RLS, RPC or matching change. Skill identity remains skill_id.

DO $$
DECLARE
  v_count integer;
  v_matched integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.skills;
  SELECT count(*) INTO v_matched
  FROM public.skills AS s
  JOIN (VALUES
    ('f2f28666-6ada-42a8-adf4-caf6e5c553c9'::uuid, 'Aircon Repair'),
    ('02be35a0-4c39-4f91-a684-93a3d5b54248'::uuid, 'Appliance Repair'),
    ('ac36af46-4c0c-4c6e-a5a7-4ae375521913'::uuid, 'Carpentry'),
    ('1f43e1d4-a443-4582-affd-a19c0617592f'::uuid, 'Cooking'),
    ('42300aaf-611f-434b-b504-f6f47bafa14d'::uuid, 'Electrical Work'),
    ('17e02f3a-1b75-428f-98a2-75bb9cfd13ae'::uuid, 'Gardening'),
    ('90be7a80-35e1-49ba-a2c8-c4689212603f'::uuid, 'General Labor'),
    ('63b4db38-c7d4-415f-8e87-6e4e98506af8'::uuid, 'House Cleaning'),
    ('f73ea827-3e32-44a9-98a2-4cb59978c83a'::uuid, 'Laundry'),
    ('58050052-cfa7-4e2b-8cd1-6e74f20d468f'::uuid, 'Masonry'),
    ('45a65bb3-c7dc-4a7c-ae47-5db1ced919f4'::uuid, 'Motorcycle Repair'),
    ('5a73f57b-f2d7-46c4-b774-7f8323d3c516'::uuid, 'Painting'),
    ('c7f7a879-6a4c-49fa-b9f0-544a8b60b88e'::uuid, 'Plumbing'),
    ('aab5b18c-de07-4de0-b888-464b3bd83913'::uuid, 'Sewing'),
    ('57e6a000-a5ac-4cd9-b5de-1440ea03558e'::uuid, 'Tile Setting'),
    ('9179ad4e-dc07-410a-aacf-6a2438dbc467'::uuid, 'Welding')
  ) AS approved(id, skill_name) ON approved.id = s.id AND approved.skill_name = s.skill_name;
  IF v_count <> 16 OR v_matched <> 16 THEN
    RAISE EXCEPTION '4Ps catalog: expected the approved 16-skill catalog, found % rows (% matched)', v_count, v_matched
      USING ERRCODE = 'P0001';
  END IF;
END $$;

-- Clarified names, same ids.
UPDATE public.skills AS s SET skill_name = r.new_name
FROM (VALUES
  ('90be7a80-35e1-49ba-a2c8-c4689212603f'::uuid, 'Moving & Hauling'),
  ('f2f28666-6ada-42a8-adf4-caf6e5c553c9'::uuid, 'Aircon Cleaning & Repair'),
  ('f73ea827-3e32-44a9-98a2-4cb59978c83a'::uuid, 'Laundry & Ironing'),
  ('1f43e1d4-a443-4582-affd-a19c0617592f'::uuid, 'Cooking & Food Prep'),
  ('17e02f3a-1b75-428f-98a2-75bb9cfd13ae'::uuid, 'Gardening & Landscaping'),
  ('aab5b18c-de07-4de0-b888-464b3bd83913'::uuid, 'Sewing & Dressmaking')
) AS r(id, new_name)
WHERE s.id = r.id;

-- New skills, fixed ids.
INSERT INTO public.skills (id, skill_name) VALUES
  ('186526be-1633-4470-9d50-356dbe65cc31', 'Roofing & Gutter Repair'),
  ('c619288a-aa55-49c3-a65a-f92d20e847e9', 'Glass & Aluminum Works'),
  ('d724bcf8-4dc1-43d7-b972-c09302326990', 'Electronics & Cellphone Repair'),
  ('45d9636f-e396-4ef9-8295-1f92e79c8800', 'Driving'),
  ('591426b4-3e3c-42c1-9afd-cdf46d7dac07', 'Catering & Event Help'),
  ('eeed1bad-d9e5-4879-bffc-c548f3baed68', 'Baking'),
  ('b1ca2177-a90e-473f-a3be-4bd5253072ea', 'Pest Control'),
  ('d7e7d525-9d07-448a-8b79-b1f1565f39b3', 'Caregiving'),
  ('05c8676d-0836-46ae-9994-d4b7b80f9a12', 'Child Care (Yaya)'),
  ('e97fc357-8f6c-4c46-90d8-e1f4f24f999e', 'Massage Therapy'),
  ('86953d01-06b1-406e-ab42-94549204b054', 'Haircut & Barbering'),
  ('f9abc619-dacf-4897-99e7-46ac47abf8c1', 'Manicure & Pedicure'),
  ('2276d8c6-1e54-4f0e-b7b2-406bd85ffd64', 'Pet Care'),
  ('9858d5fb-8e86-461a-9e29-06e4f2638716', 'Tutoring');

-- Four categories for every skill.
UPDATE public.skills AS s SET category = c.category
FROM (VALUES
  ('c7f7a879-6a4c-49fa-b9f0-544a8b60b88e'::uuid, 'Home repair & construction'),
  ('42300aaf-611f-434b-b504-f6f47bafa14d'::uuid, 'Home repair & construction'),
  ('ac36af46-4c0c-4c6e-a5a7-4ae375521913'::uuid, 'Home repair & construction'),
  ('58050052-cfa7-4e2b-8cd1-6e74f20d468f'::uuid, 'Home repair & construction'),
  ('57e6a000-a5ac-4cd9-b5de-1440ea03558e'::uuid, 'Home repair & construction'),
  ('5a73f57b-f2d7-46c4-b774-7f8323d3c516'::uuid, 'Home repair & construction'),
  ('9179ad4e-dc07-410a-aacf-6a2438dbc467'::uuid, 'Home repair & construction'),
  ('186526be-1633-4470-9d50-356dbe65cc31'::uuid, 'Home repair & construction'),
  ('c619288a-aa55-49c3-a65a-f92d20e847e9'::uuid, 'Home repair & construction'),
  ('f2f28666-6ada-42a8-adf4-caf6e5c553c9'::uuid, 'Appliance & vehicle'),
  ('02be35a0-4c39-4f91-a684-93a3d5b54248'::uuid, 'Appliance & vehicle'),
  ('45a65bb3-c7dc-4a7c-ae47-5db1ced919f4'::uuid, 'Appliance & vehicle'),
  ('d724bcf8-4dc1-43d7-b972-c09302326990'::uuid, 'Appliance & vehicle'),
  ('45d9636f-e396-4ef9-8295-1f92e79c8800'::uuid, 'Appliance & vehicle'),
  ('63b4db38-c7d4-415f-8e87-6e4e98506af8'::uuid, 'Household services'),
  ('f73ea827-3e32-44a9-98a2-4cb59978c83a'::uuid, 'Household services'),
  ('1f43e1d4-a443-4582-affd-a19c0617592f'::uuid, 'Household services'),
  ('17e02f3a-1b75-428f-98a2-75bb9cfd13ae'::uuid, 'Household services'),
  ('90be7a80-35e1-49ba-a2c8-c4689212603f'::uuid, 'Household services'),
  ('591426b4-3e3c-42c1-9afd-cdf46d7dac07'::uuid, 'Household services'),
  ('eeed1bad-d9e5-4879-bffc-c548f3baed68'::uuid, 'Household services'),
  ('b1ca2177-a90e-473f-a3be-4bd5253072ea'::uuid, 'Household services'),
  ('d7e7d525-9d07-448a-8b79-b1f1565f39b3'::uuid, 'Care & personal services'),
  ('05c8676d-0836-46ae-9994-d4b7b80f9a12'::uuid, 'Care & personal services'),
  ('aab5b18c-de07-4de0-b888-464b3bd83913'::uuid, 'Care & personal services'),
  ('e97fc357-8f6c-4c46-90d8-e1f4f24f999e'::uuid, 'Care & personal services'),
  ('86953d01-06b1-406e-ab42-94549204b054'::uuid, 'Care & personal services'),
  ('f9abc619-dacf-4897-99e7-46ac47abf8c1'::uuid, 'Care & personal services'),
  ('2276d8c6-1e54-4f0e-b7b2-406bd85ffd64'::uuid, 'Care & personal services'),
  ('9858d5fb-8e86-461a-9e29-06e4f2638716'::uuid, 'Care & personal services')
) AS c(id, category)
WHERE s.id = c.id;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.skills) <> 30
     OR EXISTS (SELECT 1 FROM public.skills WHERE category IS NULL) THEN
    RAISE EXCEPTION '4Ps catalog: expected 30 categorised skills after apply' USING ERRCODE = 'P0001';
  END IF;
END $$;
