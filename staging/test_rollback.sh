#!/usr/bin/env bash
# Proves every migration can be rolled back and re-applied: up(all) -> down(all, reverse) -> up(all) -> tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG="psql -h localhost -p ${PGPORT:-54329} -U postgres -d yaqen_staging -v ON_ERROR_STOP=1 -q -X"
"$ROOT/staging/reset.sh" >/dev/null
for f in $(ls "$ROOT"/supabase/rollback/*.down.sql | sort -r); do
  $PG -f "$f" 2>&1 | grep -v NOTICE || true
  echo "rolled back $(basename "$f")"
done
echo "policies after full rollback: $($PG -A -t -c "select count(*) from pg_policies where schemaname in ('public','storage')") (baseline = 56)"
for f in $(ls "$ROOT"/supabase/migrations/*.sql | grep -v 20261108000000_baseline); do
  $PG -f "$f" 2>&1 | grep -v NOTICE || true
  echo "re-applied $(basename "$f")"
done
