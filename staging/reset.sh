#!/usr/bin/env bash
# Recreate the local staging database: Supabase stubs + migrations in order.
# UNTIL=<version prefix> stops after that migration (used to reproduce the "before" state).
set -euo pipefail
PGPORT="${PGPORT:-54329}"
PG="psql -h localhost -p $PGPORT -U postgres -v ON_ERROR_STOP=1 -q"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${DB:-yaqen_staging}"
$PG -d postgres -c "drop database if exists $DB" -c "create database $DB" 2>/dev/null
$PG -d "$DB" -f "$ROOT/staging/supabase_stubs.sql" 2>/dev/null
for f in "$ROOT"/supabase/migrations/*.sql; do
  v="$(basename "$f" | cut -d_ -f1)"
  $PG -d "$DB" -f "$f"
  echo "applied $(basename "$f")"
  if [ -n "${UNTIL:-}" ] && [ "$v" = "$UNTIL" ]; then break; fi
done
