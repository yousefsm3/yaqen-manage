#!/usr/bin/env bash
# Runs the database test-suite on a fresh local staging DB.
#   tests/run_db_tests.sh            -> all migrations, all tests
#   UNTIL=20261108000000 tests/run_db_tests.sh   -> baseline only ("before" evidence)
#   NOPERF=1 ...                      -> skip the 1,500-employee load scenario
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGPORT="${PGPORT:-54329}"
PG="psql -h localhost -p $PGPORT -U postgres -d ${DB:-yaqen_staging} -q -X"
[ -z "${NORESET:-}" ] && { "$ROOT/staging/reset.sh" >/dev/null 2>"$ROOT/.reset_errors.log" || { echo "MIGRATIONS FAILED"; grep -v NOTICE "$ROOT/.reset_errors.log" | tail -20; exit 2; }; }
$PG -v ON_ERROR_STOP=1 -f "$ROOT/tests/db/00_lib.sql" >/dev/null
$PG -v ON_ERROR_STOP=1 -f "$ROOT/tests/db/01_fixture.sql" >/dev/null || { echo "FIXTURE FAILED"; exit 2; }
$PG -f "$ROOT/tests/db/10_security.sql" >/dev/null 2>"$ROOT/.test_errors.log"
$PG -f "$ROOT/tests/db/11_new_functions.sql" >/dev/null 2>>"$ROOT/.test_errors.log"
[ -z "${NOPERF:-}" ] && $PG -f "$ROOT/tests/db/20_perf.sql" >/dev/null 2>>"$ROOT/.test_errors.log"
$PG -A -F ' | ' -t -c "select case when ok then 'PASS' else 'FAIL' end, issue, name, left(detail, 110) from qa.results order by issue, n"
$PG -A -t -c "select '---- ' || count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed of ' || count(*) from qa.results"
fails=$($PG -A -t -c "select count(*) from qa.results where not ok")
[ "$fails" = "0" ]
