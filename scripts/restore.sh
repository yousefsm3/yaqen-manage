#!/usr/bin/env bash
# Restore a backup made by scripts/backup.sh into TARGET_URL and verify it against the manifest.
#   TARGET_URL=postgres://... [BACKUP_PASSPHRASE=...] scripts/restore.sh backups/yaqen-<ts>.dump[.gpg]
# NEVER point TARGET_URL at production unless you are recovering from an incident (RUNBOOK.md, "Restore").
# The target must be an empty database prepared with the Supabase roles/schemas (a fresh Supabase project,
# or staging/supabase_stubs.sql locally). Exit code 0 only if every table's count and checksum match.
set -euo pipefail
: "${TARGET_URL:?set TARGET_URL}"
IN="${1:?backup file}"; BASE="${IN%.gpg}"; BASE="${BASE%.dump}"
DUMP="$IN"
if [[ "$IN" == *.gpg ]]; then
  : "${BACKUP_PASSPHRASE:?encrypted backup: set BACKUP_PASSPHRASE}"
  DUMP="$(mktemp --suffix=.dump)"; trap 'rm -f "$DUMP"' EXIT
  gpg --batch --yes --pinentry-mode loopback --passphrase "$BACKUP_PASSPHRASE" -d -o "$DUMP" "$IN"
fi
if [ -f "$BASE.sha256" ] && [ "$(sha256sum "$DUMP" | cut -d' ' -f1)" != "$(cat "$BASE.sha256")" ]; then
  echo "CHECKSUM MISMATCH: backup file is damaged" >&2; exit 3
fi

# Roles named in GRANTs that the target does not have would abort the restore. CREATE_MISSING_ROLES=1 (drill only)
# creates them as NOLOGIN placeholders so the privileges can be restored and compared.
if [ "${CREATE_MISSING_ROLES:-}" = "1" ]; then
  for r in $(pg_restore -f - "$DUMP" | grep -oE '^(GRANT|REVOKE) .* (TO|FROM) [^;]+' | sed -E 's/.* (TO|FROM) //; s/ WITH GRANT OPTION//' | tr ',' '\n' | tr -d ' "' | sort -u); do
    [ "$r" = "PUBLIC" ] && continue
    psql "$TARGET_URL" -X -q -v ON_ERROR_STOP=1 -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname = '$r') then create role \"$r\" nologin; end if; end \$\$"
  done
fi

# --clean drops the target's copies of the dumped objects first; any real error aborts (exit-on-error).
# (A restore that stops half-way can still have all the rows but miss constraints/policies: the manifest
#  below also compares those object counts, so that case fails instead of looking green.)
pg_restore -d "$TARGET_URL" --no-owner --clean --if-exists --exit-on-error "$DUMP"

psql "$TARGET_URL" -X -A -t -v ON_ERROR_STOP=1 -f "$(dirname "$0")/manifest.sql" > "$BASE.restored.manifest"
if diff -u "$BASE.manifest" "$BASE.restored.manifest"; then
  echo "RESTORE VERIFIED: $(grep -c ^table "$BASE.manifest") tables (rows + checksums) and $(grep -c ^objects "$BASE.manifest") object counts match"
else
  echo "RESTORE MISMATCH (see diff above)" >&2; exit 4
fi
