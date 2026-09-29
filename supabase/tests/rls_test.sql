-- RLS and constraint tests for the initial schema: user A can never read or
-- write user B's rows. Run with `pnpm db:test` (supabase test db).
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(33);

-- Fixtures, as the table owner (bypasses RLS).
\set user_a '''aaaaaaaa-0000-0000-0000-000000000001'''
\set user_b '''bbbbbbbb-0000-0000-0000-000000000002'''
\set dev_a  '''aaaaaaaa-0000-0000-0000-00000000000a'''
\set dev_a_revoked '''aaaaaaaa-0000-0000-0000-00000000000f'''
\set dev_b  '''bbbbbbbb-0000-0000-0000-00000000000b'''

INSERT INTO auth.users (id, email) VALUES
  (:user_a, 'a@example.test'),
  (:user_b, 'b@example.test');
INSERT INTO public.profiles (id) VALUES (:user_a), (:user_b);
INSERT INTO public.devices (id, user_id) VALUES (:dev_a, :user_a), (:dev_b, :user_b);
INSERT INTO public.devices (id, user_id, revoked_at) VALUES (:dev_a_revoked, :user_a, now());
INSERT INTO public.wrapped_keys (user_id, method, key_version, wrapped_dk) VALUES
  (:user_a, 'recovery', 1, '\x01'),
  (:user_b, 'recovery', 1, '\x02');
INSERT INTO public.rollup_blobs (user_id, device_id, day, key_version, nonce, ciphertext, version) VALUES
  (:user_a, :dev_a, '2026-09-27', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 4096), 'hex'), 1),
  (:user_b, :dev_b, '2026-09-27', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 4096), 'hex'), 1);

-- Signed in as user A.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', :user_a, 'role', 'authenticated')::text, true);

-- Reads: only A's rows are visible.
SELECT results_eq('SELECT id FROM public.profiles', ARRAY[:user_a::uuid], 'A reads only own profile');
SELECT results_eq('SELECT count(*)::int FROM public.devices', ARRAY[2], 'A reads only own devices');
SELECT is_empty(format('SELECT 1 FROM public.devices WHERE user_id = %L', :user_b), 'A cannot read B devices');
SELECT results_eq('SELECT user_id FROM public.wrapped_keys', ARRAY[:user_a::uuid], 'A reads only own wrapped keys');
SELECT results_eq('SELECT user_id FROM public.rollup_blobs', ARRAY[:user_a::uuid], 'A reads only own blobs');

-- Writes into B's rows: rejected on insert, no-ops on update and delete.
SELECT throws_ok(
  format($$INSERT INTO public.rollup_blobs (user_id, device_id, day, key_version, nonce, ciphertext, version)
    VALUES (%L, %L, '2026-09-28', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 4096), 'hex'), 1)$$, :user_b, :dev_b),
  '42501', NULL, 'A cannot insert a blob as B');
SELECT results_eq(
  format('WITH u AS (UPDATE public.rollup_blobs SET version = 99 WHERE user_id = %L RETURNING 1) SELECT count(*)::int FROM u', :user_b),
  ARRAY[0], 'A cannot update B blobs');
SELECT results_eq(
  format('WITH d AS (DELETE FROM public.rollup_blobs WHERE user_id = %L RETURNING 1) SELECT count(*)::int FROM d', :user_b),
  ARRAY[0], 'A cannot delete B blobs');
SELECT throws_ok(
  format($$INSERT INTO public.devices (id, user_id) VALUES (gen_random_uuid(), %L)$$, :user_b),
  '42501', NULL, 'A cannot register a device for B');
SELECT results_eq(
  format('WITH u AS (UPDATE public.devices SET revoked_at = now() WHERE user_id = %L RETURNING 1) SELECT count(*)::int FROM u', :user_b),
  ARRAY[0], 'A cannot revoke B devices');
SELECT results_eq(
  format('WITH d AS (DELETE FROM public.devices WHERE user_id = %L RETURNING 1) SELECT count(*)::int FROM d', :user_b),
  ARRAY[0], 'A cannot delete B devices');
SELECT throws_ok(
  format($$UPDATE public.devices SET user_id = %L WHERE id = %L$$, :user_b, :dev_a),
  '42501', NULL, 'A cannot hand a device to B');
SELECT throws_ok(
  format($$INSERT INTO public.wrapped_keys (user_id, method, key_version, wrapped_dk) VALUES (%L, 'passphrase', 1, '\x03')$$, :user_b),
  '42501', NULL, 'A cannot insert a wrapped key for B');
SELECT results_eq(
  format($$WITH u AS (UPDATE public.wrapped_keys SET wrapped_dk = '\x04' WHERE user_id = %L RETURNING 1) SELECT count(*)::int FROM u$$, :user_b),
  ARRAY[0], 'A cannot overwrite B wrapped keys');
SELECT results_eq(
  format('WITH d AS (DELETE FROM public.wrapped_keys WHERE user_id = %L RETURNING 1) SELECT count(*)::int FROM d', :user_b),
  ARRAY[0], 'A cannot delete B wrapped keys');
SELECT throws_ok(
  format($$INSERT INTO public.profiles (id) VALUES (%L)$$, :user_a),
  '42501', NULL, 'profiles are not writable by clients');

-- A's own blob rules.
SELECT throws_ok(
  format($$INSERT INTO public.rollup_blobs (user_id, device_id, day, key_version, nonce, ciphertext, version)
    VALUES (%L, %L, '2026-09-28', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 4096), 'hex'), 1)$$, :user_a, :dev_b),
  '42501', NULL, 'A cannot write a blob under B device');
SELECT throws_ok(
  format($$INSERT INTO public.rollup_blobs (user_id, device_id, day, key_version, nonce, ciphertext, version)
    VALUES (%L, %L, '2026-09-28', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 4096), 'hex'), 1)$$, :user_a, :dev_a_revoked),
  '42501', NULL, 'A cannot write a blob from a revoked device');
SELECT throws_ok(
  format($$INSERT INTO public.rollup_blobs (user_id, device_id, day, key_version, nonce, ciphertext, version)
    VALUES (%L, %L, '2026-09-28', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 5000), 'hex'), 1)$$, :user_a, :dev_a),
  '23514', NULL, 'ciphertext outside the size buckets is rejected');
SELECT throws_ok(
  format($$INSERT INTO public.rollup_blobs (user_id, device_id, day, key_version, nonce, ciphertext, version)
    VALUES (%L, %L, '2026-09-28', 1, decode(repeat('00', 12), 'hex'), decode(repeat('00', 4096), 'hex'), 1)$$, :user_a, :dev_a),
  '23514', NULL, 'nonce must be 24 bytes');
SELECT throws_ok(
  format($$INSERT INTO public.rollup_blobs (user_id, device_id, period, day, key_version, nonce, ciphertext, version)
    VALUES (%L, %L, 'week', '2026-09-28', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 4096), 'hex'), 1)$$, :user_a, :dev_a),
  '23514', NULL, 'period must be day or month');
SELECT lives_ok(
  format($$INSERT INTO public.rollup_blobs (user_id, device_id, day, key_version, nonce, ciphertext, version)
    VALUES (%L, %L, '2026-09-28', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 16384), 'hex'), 1)$$, :user_a, :dev_a),
  'A can write a 16 KB blob from an active own device');
SELECT lives_ok(
  format($$INSERT INTO public.rollup_blobs AS b (user_id, device_id, day, key_version, nonce, ciphertext, version)
    VALUES (%L, %L, '2026-09-28', 1, decode(repeat('00', 24), 'hex'), decode(repeat('00', 4096), 'hex'), 2)
    ON CONFLICT (user_id, device_id, period, day) DO UPDATE
    SET ciphertext = EXCLUDED.ciphertext, nonce = EXCLUDED.nonce, version = EXCLUDED.version$$, :user_a, :dev_a),
  'A can upsert a newer version');
SELECT throws_ok(
  format($$UPDATE public.rollup_blobs SET version = 2 WHERE user_id = %L AND day = '2026-09-28'$$, :user_a),
  'P0001', 'stale version', 'same version is rejected as stale');
SELECT throws_ok(
  format($$UPDATE public.rollup_blobs SET version = 1 WHERE user_id = %L AND day = '2026-09-28'$$, :user_a),
  'P0001', 'stale version', 'older version is rejected as stale');
SELECT lives_ok(
  format($$DELETE FROM public.rollup_blobs WHERE user_id = %L AND day = '2026-09-28'$$, :user_a),
  'A can delete own blobs (monthly compaction)');

-- Device cap: A has 1 active device, so 9 more succeed and the 11th fails.
SELECT lives_ok(
  format($$INSERT INTO public.devices (id, user_id) SELECT gen_random_uuid(), %L FROM generate_series(1, 9)$$, :user_a),
  'A can have 10 active devices');
SELECT throws_ok(
  format($$INSERT INTO public.devices (id, user_id) VALUES (gen_random_uuid(), %L)$$, :user_a),
  'P0001', 'device limit reached', 'the 11th active device is rejected');

-- Signed in as user B: A's rows stay invisible, B's fixtures are intact.
SELECT set_config('request.jwt.claims', json_build_object('sub', :user_b, 'role', 'authenticated')::text, true);
SELECT results_eq('SELECT count(*)::int FROM public.rollup_blobs', ARRAY[1], 'B still has exactly its own blob');
SELECT results_eq('SELECT version FROM public.rollup_blobs', ARRAY[1], 'B blob was not modified by A');
SELECT results_eq('SELECT count(*)::int FROM public.devices', ARRAY[1], 'B sees only its own device');

-- Signed out (anon key only): nothing is visible.
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
SELECT is_empty('SELECT 1 FROM public.rollup_blobs UNION ALL SELECT 1 FROM public.devices
  UNION ALL SELECT 1 FROM public.wrapped_keys UNION ALL SELECT 1 FROM public.profiles',
  'anon reads nothing');
SELECT throws_ok(
  format($$INSERT INTO public.devices (id, user_id) VALUES (gen_random_uuid(), %L)$$, :user_a),
  '42501', NULL, 'anon cannot register devices');

SELECT * FROM finish();
ROLLBACK;
