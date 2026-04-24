-- 001_create_all_tables.sql
-- SkillMatch: All table definitions in dependency order

-- Level 0: No dependencies
CREATE TABLE skills (...);

-- Level 1: Depends on users
CREATE TABLE worker_profiles (...);
CREATE TABLE job_postings (...);
CREATE TABLE notifications (...);

-- Level 2: Depends on Level 0 + Level 1
CREATE TABLE worker_skills (...);
CREATE TABLE portfolio_items (...);
CREATE TABLE job_skills (...);

-- Level 3: Depends on Level 1
CREATE TABLE bookings (...);

-- Level 4: Depends on Level 3
CREATE TABLE ratings (...);
