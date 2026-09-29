import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { test } from 'node:test';
const migration = readFileSync(new URL('../migrations/20260924090000_v4_loc_01_worker_opportunity_location.sql', import.meta.url));
const rpc = migration.toString();
const forward = readFileSync(new URL('../migrations/20260929023803_ft06_worker_eligibility_invalidation.sql', import.meta.url), 'utf8');
const broadcaster = readFileSync(new URL('../migrations/20260922071511_r6_worker_opportunity_invalidation.sql', import.meta.url), 'utf8');
test('already-hosted reconciliation bytes are unchanged', () => {
  assert.equal(createHash('sha256').update(migration).digest('hex'), '4444a6eaba0b81bbac1b53e681d05457f98e795c17cae1e7d91755607664534c');
});
test('preaccept caller is derived and existing authoritative eligibility is reused', () => {
  assert.match(rpc, /auth\.uid\(\)/i);
  assert.match(rpc, /private\.is_active_worker\(\)/i);
  assert.match(rpc, /is_verified/i);
  assert.match(rpc, /public\.list_my_job_opportunities\(\)/i);
  assert.doesNotMatch(rpc, /p_worker_id|GRANT\s+SELECT/i);
});
test('forward migration extends only existing empty invalidation triggers', () => {
  assert.equal((forward.match(/CREATE TRIGGER/g) ?? []).length, 3);
  assert.match(forward, /UPDATE OF is_active, role, barangay, city ON public\.users/);
  for (const table of ['worker_profiles', 'worker_skills']) assert.match(forward, new RegExp(`AFTER INSERT OR UPDATE OR DELETE ON public\\.${table}`));
  assert.equal((forward.match(/EXECUTE FUNCTION private\.r6_broadcast_job_opportunities_changed\(\)/g) ?? []).length, 3);
  const statements = forward.replace(/--[^\n]*/g, '');
  assert.doesNotMatch(statements, /CREATE TABLE|ALTER TABLE|CREATE (?:OR REPLACE )?FUNCTION|GRANT|POLICY|latitude|longitude|address|compute_job_matches|location_points/i);
});
test('existing broadcaster sends no row or protected payload', () => {
  assert.match(broadcaster, /realtime\.send\(\s*'\{\}'::jsonb,\s*'job_opportunities_changed',\s*'worker:opportunities',\s*true/);
  assert.match(broadcaster, /FROM PUBLIC, anon, authenticated, service_role/);
});
