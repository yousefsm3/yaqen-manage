#!/usr/bin/env bash
# C2 (independent of the Supabase plan): logical backup of the platform database.
#   DATABASE_URL=postgres://...  BACKUP_PASSPHRASE=...  scripts/backup.sh [out_dir]
# Produces <out_dir>/yaqen-<UTC timestamp>.dump(.gpg) + a .manifest with row counts and per-table checksums,
# so a restore can be verified (scripts/restore.sh checks it).
# Notes:
#  - pg_dump's major version must be >= the server's (production is Postgres 17 -> postgresql-client-17).
#  - Dumps schemas public + storage metadata. Auth users (auth schema) are included only with INCLUDE_AUTH=1,
#    because restoring auth into another Supabase project needs Supabase's own procedure (see docs/RUNBOOK.md).
#  - Files in Storage buckets (photos, room files) are NOT inside the database: back them up separately (RUNBOOK).
#  - Privileges (GRANTs to anon/authenticated/service_role) MUST be kept: without them the API cannot read
#    anything after a restore. This was found by the restore test (docs/BACKUP_RESTORE_REPORT.md).
#  - Without BACKUP_PASSPHRASE the dump is NOT encrypted; never upload an unencrypted dump anywhere.
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
OUT="${1:-./backups}"; mkdir -p "$OUT"
TS="$(date -u +%Y%m%dT%H%M%SZ)"; BASE="$OUT/yaqen-$TS"
SCHEMAS=(--schema=public --schema=storage); [ "${INCLUDE_AUTH:-}" = "1" ] && SCHEMAS+=(--schema=auth)

pg_dump "$DATABASE_URL" -Fc --no-owner "${SCHEMAS[@]}" -f "$BASE.dump"

# manifest: table -> row count and md5 of the sorted rows (detects silent data loss/corruption on restore)
psql "$DATABASE_URL" -X -A -t -v ON_ERROR_STOP=1 -f "$(dirname "$0")/manifest.sql" > "$BASE.manifest"
sha256sum "$BASE.dump" | cut -d' ' -f1 > "$BASE.sha256"

if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
  gpg --batch --yes --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" --symmetric --cipher-algo AES256 -o "$BASE.dump.gpg" "$BASE.dump"
  rm -f "$BASE.dump"; echo "encrypted: $BASE.dump.gpg"
else
  echo "WARNING: BACKUP_PASSPHRASE not set - $BASE.dump is not encrypted" >&2
fi
echo "manifest: $BASE.manifest ($(grep -c ^table "$BASE.manifest") tables)"
