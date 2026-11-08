#!/usr/bin/env bash
# Concurrency test on staging (needs the perf dataset: run tests/run_db_tests.sh first).
# Measures the DATABASE only, on this machine. It is not a network/API load test (see docs/PERFORMANCE_REPORT.md).
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
PGB="${PGBENCH:-pgbench} -h localhost -p ${PGPORT:-54329} -U postgres -n -M prepared"
for c in ${CLIENTS:-10 50 100}; do
  echo "=== $c concurrent sessions, 30 s: 90% employees opening invoices/vehicles, 10% admin dashboard"
  $PGB -c "$c" -j 2 -T "${SECS:-30}" -r -f "$D/employee_page.sql@9" -f "$D/admin_dashboard.sql@1" "${DB:-yaqen_staging}" 2>&1 \
    | grep -E "^=|number of clients|processed|failed transactions|latency average|tps =|SQL script|weight|^ - latency"
done
