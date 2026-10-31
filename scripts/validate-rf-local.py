"""Reproduce RF SQL validation without a network-accessible database.

Requires the already cached Supabase Postgres 17.6.1.084 image. No pulls,
host ports, hosted SQL, credentials, or Git operations are performed.
Platform/application dumps contain schema only. The seed input is explicitly
LOCAL-ONLY catalog/bucket fixture data, never a repair of deployed migrations.

Example:
  python scripts/validate-rf-local.py --platform-schema PLATFORM.sql \
    --application-schema PRE_RF.sql --local-seed LOCAL_ONLY.sql --output NEW_DIR
Omit --application-schema and pass --prerequisite-fixture FOUR_ROWS.sql to
reproduce the original migration-26 failure, then the fixture-assisted replay.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid


IMAGE = "public.ecr.aws/supabase/postgres:17.6.1.084"
TESTS = ["rf01_location_pins.sql", "rf02_booking_calls.sql",
         "rf03_verify_worker_revoke.sql", "rf_termination_concurrency.sql",
         "v3_db_03_worker_id_review.sql"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform-schema", type=Path, required=True)
    parser.add_argument("--application-schema", type=Path)
    parser.add_argument("--local-seed", type=Path)
    parser.add_argument("--prerequisite-fixture", type=Path)
    parser.add_argument("--recovery", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if bool(args.application_schema) != bool(args.local_seed):
        parser.error("hosted-schema mode requires --application-schema and --local-seed together")
    if not args.application_schema and not args.prerequisite_fixture:
        parser.error("repository replay requires the explicit --prerequisite-fixture")
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    name = "skillmatch-rf-" + uuid.uuid4().hex[:12]
    manifest = {str(p.relative_to(repo)).replace("\\", "/"): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (repo / "supabase/migrations").glob("*.sql")}
    (output / "migration-source-hashes.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    def run(cmd, text=None, check=True):
        # Binary pipes preserve dumped function bodies exactly on Windows.
        result = subprocess.run(cmd, input=text.encode("utf-8") if text is not None else None,
                                capture_output=True, timeout=55)
        result.stdout = result.stdout.decode("utf-8", errors="replace")
        result.stderr = result.stderr.decode("utf-8", errors="replace")
        if check and result.returncode:
            raise RuntimeError(result.stderr[-1800:])
        return result

    def sql(text, label, admin=False, check=True, transaction=True):
        cmd = ["docker", "exec", "-i"]
        if admin:
            # This fixed password exists only in this new network-none container.
            cmd += ["--env", "PGPASSWORD=postgres"]
        cmd += [name, "psql", "-X", "-w", "-At", "-U", "supabase_admin" if admin else "postgres",
                "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
        if transaction:
            cmd += ["--single-transaction"]
        result = run(cmd, text, check=False)
        log = result.stdout + result.stderr
        (output / (label + ".log")).write_text(log, encoding="utf-8")
        if check and (result.returncode or re.search(r"NOTICE:\s+FAIL\b", log)):
            raise RuntimeError(label + ": " + log[-1800:])
        return result

    created = False
    try:
        run(["docker", "create", "--pull=never", "--network=none", "--restart=no",
             "--name", name, "--label", "skillmatch.task=rf-integration",
             "--env", "POSTGRES_PASSWORD=postgres", IMAGE,
             "postgres", "-D", "/etc/postgresql", "-c", "listen_addresses=127.0.0.1"])
        created = True
        container = json.loads(run(["docker", "inspect", name]).stdout)[0]
        assert container["HostConfig"]["NetworkMode"] == "none"
        assert not container["HostConfig"].get("PortBindings")
        assert not container["HostConfig"]["Privileged"]
        assert container["Image"] == "sha256:95d92e9563121189086690a4b7f8f2b711a4809a2499f45592199aae68ebae5f"
        (output / "containment.json").write_text(json.dumps({
            "container": name, "image_id": container["Image"], "network": "none", "published_ports": {},
        }, indent=2), encoding="utf-8")
        run(["docker", "start", name])
        for _ in range(30):
            main_process = run(["docker", "exec", name, "cat", "/proc/1/comm"], check=False)
            if main_process.stdout.strip() in ("postgres", ".postgres-wrapp") and run(
                ["docker", "exec", name, "pg_isready", "-U", "postgres"], check=False
            ).returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("isolated database did not become ready")
        hba = run(["docker", "exec", name, "cat", "/etc/postgresql/pg_hba.conf"]).stdout
        hba = "host all all 127.0.0.1/32 scram-sha-256\nhost all all ::1/128 scram-sha-256\n" + hba
        run(["docker", "exec", "-i", name, "sh", "-c", "cat > /etc/postgresql/pg_hba.conf"], hba)
        sql("SELECT pg_reload_conf();", "password-auth", admin=True)
        platform = args.platform_schema.read_bytes().decode("utf-8-sig")
        # Application policies are installed by the repository migrations, or
        # restored after their referenced application objects in snapshot mode.
        policies = re.findall(r"(?m)^CREATE POLICY\s[\s\S]*?;\s*", platform)
        platform = re.sub(r"(?m)^CREATE POLICY\s[\s\S]*?;\s*", "", platform)
        sql("CREATE ROLE supabase_realtime_admin NOLOGIN NOINHERIT; "
            "DROP SCHEMA auth CASCADE; DROP SCHEMA storage CASCADE; DROP SCHEMA realtime CASCADE;\n" + platform,
            "platform-schema", admin=True)
        # Schema-scoped dumps omit extension-owned objects. Match the captured
        # hosted versions explicitly, including pg_net's queue/functions.
        sql("CREATE EXTENSION IF NOT EXISTS pg_net VERSION '0.20.0'; "
            "CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions VERSION '1.3'; "
            "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\" WITH SCHEMA extensions VERSION '1.1';",
            "platform-extensions")
        migrations = sorted((repo / "supabase/migrations").glob("*.sql"))
        rf = [p for p in migrations if p.name.startswith("20261015") and "_rf0" in p.name]
        assert len(rf) == 3
        if args.application_schema:
            sql("ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM PUBLIC,anon,authenticated,service_role; "
                "ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role; "
                "ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon,authenticated,service_role;",
                "empty-restore-defaults", admin=True)
            sql(args.application_schema.read_bytes().decode("utf-8-sig"), "hosted-schema-baseline")
            sql("\n".join(policies), "application-storage-policies", admin=True)
            sql(args.local_seed.read_text(encoding="utf-8-sig"), "local-only-catalog-bucket-fixture", admin=True)
            selected = rf
        else:
            selected = migrations
        for migration in selected:
            result = sql(migration.read_bytes().decode("utf-8-sig"), migration.stem, check=False)
            if result.returncode and migration.name.startswith("20260916120000") and not args.application_schema:
                if "locked original skill row missing" not in result.stderr:
                    raise RuntimeError(result.stderr[-1800:])
                print("Original bootstrap defect reproduced; applying explicitly supplied LOCAL-ONLY four-row fixture.", flush=True)
                fixture = args.prerequisite_fixture.read_bytes()
                assert hashlib.sha256(fixture).hexdigest() == "e56ddae6fca6b4cb44f5988ec3a9ea55e924a2a35deb9cf234a6da5d9ab66747"
                sql(fixture.decode("utf-8-sig"), "local-only-four-row-prerequisite")
                result = sql(migration.read_text(encoding="utf-8-sig"), migration.stem + "-fixture-assisted")
            if result.returncode:
                raise RuntimeError(migration.name + ": " + result.stderr[-1800:])
        results = {}
        for test in TESTS:
            result = sql((repo / "supabase/tests" / test).read_text(encoding="utf-8-sig"), test, transaction=False)
            results[test] = len(re.findall(r"NOTICE:\s+PASS\b", result.stderr))
            print(test, results[test], "PASS", flush=True)
        if args.recovery:
            # This transaction intentionally fails at the guard and rolls back
            # all synthetic fixtures when psql exits. It never abandons a call.
            fixture_setup = (repo / "supabase/tests/rf_termination_concurrency.sql").read_text(encoding="utf-8")
            fixture_setup = fixture_setup.split("SELECT dblink_connect(", 1)[0]
            guarded = sql("BEGIN;\n" + fixture_setup +
                          "\nSELECT public.rf02_call_start('0c0c0c0c-0000-4000-8000-000000000001',"
                          "'0c0c0c0c-2000-4000-8000-00000000000a');\n" +
                          args.recovery.read_text(encoding="utf-8-sig"),
                          "recovery-refuses-unconfirmed-call", check=False, transaction=False)
            assert guarded.returncode != 0 and "RF recovery requires no shares" in guarded.stderr
            sql(args.recovery.read_text(encoding="utf-8-sig"), "compatible-recovery", transaction=False)
            sql("DO $$ BEGIN "
                "IF has_function_privilege('authenticated','public.verify_worker(uuid)','EXECUTE') "
                "OR NOT has_function_privilege('authenticated','public.approve_worker_identity(uuid)','EXECUTE') "
                "OR has_function_privilege('authenticated','public.start_my_booking_location_share(uuid)','EXECUTE') "
                "OR has_function_privilege('service_role','public.rf02_call_start(uuid,uuid)','EXECUTE') "
                "OR EXISTS (SELECT 1 FROM cron.job WHERE jobname='rf02-call-reconcile' AND active) "
                "OR (SELECT count(*) FROM pg_tables WHERE schemaname='public') <> 13 THEN "
                "RAISE EXCEPTION 'Compatible recovery invariant failed'; END IF; END $$;",
                "recovery-compatibility-invariants")
        assert all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h for p, h in manifest.items())
        (output / "results.json").write_text(json.dumps({
            "mode": "hosted-schema-with-local-fixtures" if args.application_schema else "fixture-assisted-repository-replay",
            "original_bootstrap_repaired": False, "tests": results,
        }, indent=2), encoding="utf-8")
    finally:
        if created:
            run(["docker", "stop", name], check=False)
            print("Stopped task-owned isolated container", name, flush=True)


if __name__ == "__main__":
    main()
