import { test } from 'node:test';
import assert from 'node:assert/strict';

import { checkPublicConfig } from './config.js';

const b64 = (value) => btoa(JSON.stringify(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const jwt = (payload) => `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64(payload)}.sig`;

test('accepts a hosted project URL and a publishable key', () => {
  const result = checkPublicConfig('https://abcd1234.supabase.co', 'sb_publishable_abc');
  assert.deepEqual(result, { ok: true, origin: 'https://abcd1234.supabase.co' });
});

test('accepts a legacy anon JWT key and a trailing slash', () => {
  const result = checkPublicConfig('https://abcd1234.supabase.co/', jwt({ role: 'anon' }));
  assert.equal(result.ok, true);
  assert.equal(result.origin, 'https://abcd1234.supabase.co');
});

test('accepts plain http only for a local stack', () => {
  assert.equal(checkPublicConfig('http://127.0.0.1:54321', 'sb_publishable_x').ok, true);
  assert.equal(checkPublicConfig('http://localhost:54321', 'sb_publishable_x').ok, true);
  assert.equal(checkPublicConfig('http://abcd.supabase.co', 'sb_publishable_x').ok, false);
});

test('rejects a missing or malformed URL', () => {
  assert.equal(checkPublicConfig('', 'sb_publishable_x').ok, false);
  assert.equal(checkPublicConfig(undefined, 'sb_publishable_x').ok, false);
  assert.equal(checkPublicConfig('not a url', 'sb_publishable_x').ok, false);
  assert.equal(checkPublicConfig('https://abcd.supabase.co/rest/v1', 'sb_publishable_x').ok, false);
  assert.equal(checkPublicConfig('https://user:pw@abcd.supabase.co', 'sb_publishable_x').ok, false);
});

test('rejects a secret key or any non-anon JWT', () => {
  assert.equal(checkPublicConfig('https://abcd.supabase.co', '').ok, false);
  assert.equal(checkPublicConfig('https://abcd.supabase.co', undefined).ok, false);
  assert.equal(checkPublicConfig('https://abcd.supabase.co', 'sb_secret_abc').ok, false);
  assert.equal(checkPublicConfig('https://abcd.supabase.co', jwt({ role: 'authenticated' })).ok, false);
  assert.equal(checkPublicConfig('https://abcd.supabase.co', jwt({ role: ['ser', 'vice_role'].join('') })).ok, false);
  assert.equal(checkPublicConfig('https://abcd.supabase.co', 'a.b.c').ok, false);
});
