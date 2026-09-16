-- ============================================================
-- V2-C-DB-01: SKILL CATALOG EXPANSION (16 SKILLS)
-- ============================================================
--
-- SCOPE
-- -----
-- Expands public.skills from the four development-baseline rows to
-- the approved sixteen-skill catalog.
--
-- This migration:
--   1. requires the four locked original name+UUID pairs to exist
--      with category NULL
--   2. rejects any current public.skills row that is not an exact
--      approved 16-skill name+UUID pair with category NULL
--   3. inserts the twelve approved new skills with fixed UUIDs and
--      category NULL
--
-- Approved total after a successful apply: 16 skills.
-- D-002 matching untouched. Skill identity remains skill_id.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * No rename or UUID replacement of Carpentry, Electrical Work,
--     General Labor, or Plumbing.
--   * No category population. Every skill remains category NULL.
--   * No Worker/Job skill backfill.
--   * No INSERT/UPDATE/DELETE on worker_skills, job_skills,
--     job_postings, bookings, or worker_profiles.
--   * No schema, RLS, RPC, trigger, or matching change.
--   * No proficiency scoring, category matching, synonyms, fuzzy
--     matching, or AI matching.
--   * No mobile/UI change and no category grouping.
-- ============================================================


-- ---------- 1. HARDENED CATALOG-SUBSET PRECONDITION ----------
--
-- Current public.skills must be a valid subset of the approved 16
-- exact name+UUID+NULL-category rows, and the original four must
-- already exist. Malformed states fail closed. Nothing is UPDATEd.

DO $$
DECLARE
  v_missing text;
  v_unexpected text;
BEGIN
  SELECT string_agg(original.skill_name, ', ' ORDER BY original.skill_name)
    INTO v_missing
  FROM (
    VALUES
      ('ac36af46-4c0c-4c6e-a5a7-4ae375521913'::uuid, 'Carpentry'::character varying),
      ('42300aaf-611f-434b-b504-f6f47bafa14d'::uuid, 'Electrical Work'::character varying),
      ('90be7a80-35e1-49ba-a2c8-c4689212603f'::uuid, 'General Labor'::character varying),
      ('c7f7a879-6a4c-49fa-b9f0-544a8b60b88e'::uuid, 'Plumbing'::character varying)
  ) AS original(id, skill_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.skills AS s
    WHERE s.id = original.id
      AND s.skill_name = original.skill_name
      AND s.category IS NULL
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'V2-C: locked original skill row missing or remapped (exact name+UUID and category NULL required): %',
      v_missing;
  END IF;

  SELECT string_agg(
           format(
             '%s id=%s category=%s',
             s.skill_name,
             s.id::text,
             COALESCE(s.category::text, 'NULL')
           ),
           ', '
           ORDER BY s.skill_name, s.id
         )
    INTO v_unexpected
  FROM public.skills AS s
  WHERE s.category IS NOT NULL
     OR NOT EXISTS (
       SELECT 1
       FROM (
         VALUES
           ('ac36af46-4c0c-4c6e-a5a7-4ae375521913'::uuid, 'Carpentry'::character varying),
           ('42300aaf-611f-434b-b504-f6f47bafa14d'::uuid, 'Electrical Work'::character varying),
           ('90be7a80-35e1-49ba-a2c8-c4689212603f'::uuid, 'General Labor'::character varying),
           ('c7f7a879-6a4c-49fa-b9f0-544a8b60b88e'::uuid, 'Plumbing'::character varying),
           ('58050052-cfa7-4e2b-8cd1-6e74f20d468f'::uuid, 'Masonry'::character varying),
           ('1f43e1d4-a443-4582-affd-a19c0617592f'::uuid, 'Cooking'::character varying),
           ('5a73f57b-f2d7-46c4-b774-7f8323d3c516'::uuid, 'Painting'::character varying),
           ('9179ad4e-dc07-410a-aacf-6a2438dbc467'::uuid, 'Welding'::character varying),
           ('57e6a000-a5ac-4cd9-b5de-1440ea03558e'::uuid, 'Tile Setting'::character varying),
           ('63b4db38-c7d4-415f-8e87-6e4e98506af8'::uuid, 'House Cleaning'::character varying),
           ('f73ea827-3e32-44a9-98a2-4cb59978c83a'::uuid, 'Laundry'::character varying),
           ('45a65bb3-c7dc-4a7c-ae47-5db1ced919f4'::uuid, 'Motorcycle Repair'::character varying),
           ('02be35a0-4c39-4f91-a684-93a3d5b54248'::uuid, 'Appliance Repair'::character varying),
           ('f2f28666-6ada-42a8-adf4-caf6e5c553c9'::uuid, 'Aircon Repair'::character varying),
           ('aab5b18c-de07-4de0-b888-464b3bd83913'::uuid, 'Sewing'::character varying),
           ('17e02f3a-1b75-428f-98a2-75bb9cfd13ae'::uuid, 'Gardening'::character varying)
       ) AS approved(id, skill_name)
       WHERE approved.id = s.id
         AND approved.skill_name = s.skill_name
     );

  IF v_unexpected IS NOT NULL THEN
    RAISE EXCEPTION
      'V2-C: public.skills contains a row that is not an approved 16-skill NULL-category pair: %',
      v_unexpected;
  END IF;
END $$;


-- ---------- 2. ADDITIVE INSERT OF TWELVE NEW SKILLS ----------
--
-- Idempotent only for an exact approved name+UUID pair that already
-- exists (the precondition has already required category NULL).
-- Re-applying a correct 16-skill catalog inserts 0 rows.

INSERT INTO public.skills (id, skill_name, category)
SELECT v.id, v.skill_name, NULL
FROM (
  VALUES
    ('58050052-cfa7-4e2b-8cd1-6e74f20d468f'::uuid, 'Masonry'::character varying),
    ('1f43e1d4-a443-4582-affd-a19c0617592f'::uuid, 'Cooking'::character varying),
    ('5a73f57b-f2d7-46c4-b774-7f8323d3c516'::uuid, 'Painting'::character varying),
    ('9179ad4e-dc07-410a-aacf-6a2438dbc467'::uuid, 'Welding'::character varying),
    ('57e6a000-a5ac-4cd9-b5de-1440ea03558e'::uuid, 'Tile Setting'::character varying),
    ('63b4db38-c7d4-415f-8e87-6e4e98506af8'::uuid, 'House Cleaning'::character varying),
    ('f73ea827-3e32-44a9-98a2-4cb59978c83a'::uuid, 'Laundry'::character varying),
    ('45a65bb3-c7dc-4a7c-ae47-5db1ced919f4'::uuid, 'Motorcycle Repair'::character varying),
    ('02be35a0-4c39-4f91-a684-93a3d5b54248'::uuid, 'Appliance Repair'::character varying),
    ('f2f28666-6ada-42a8-adf4-caf6e5c553c9'::uuid, 'Aircon Repair'::character varying),
    ('aab5b18c-de07-4de0-b888-464b3bd83913'::uuid, 'Sewing'::character varying),
    ('17e02f3a-1b75-428f-98a2-75bb9cfd13ae'::uuid, 'Gardening'::character varying)
) AS v(id, skill_name)
WHERE NOT EXISTS (
  SELECT 1
  FROM public.skills AS s
  WHERE s.id = v.id
    AND s.skill_name = v.skill_name
);
