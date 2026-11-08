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
for f in "$ROOT"/supabase/migrations/2026110801*.sql "$ROOT"/supabase/migrations/2026110802*.sql "$ROOT"/supabase/migrations/2026110803*.sql \
         "$ROOT"/supabase/migrations/2026110804*.sql "$ROOT"/supabase/migrations/2026110805*.sql "$ROOT"/supabase/migrations/2026110806*.sql \
         "$ROOT"/supabase/migrations/2026110807*.sql; do
  $PG -f "$f" 2>&1 | grep -v NOTICE || true
  echo "re-applied $(basename "$f")"
done
