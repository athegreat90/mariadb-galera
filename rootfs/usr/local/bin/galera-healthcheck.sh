#!/usr/bin/env bash
set -Eeuo pipefail

if [ -n "${MARIADB_ROOT_PASSWORD_FILE:-}" ] && [ -f "${MARIADB_ROOT_PASSWORD_FILE}" ]; then
  MYSQL_PWD="$(< "${MARIADB_ROOT_PASSWORD_FILE}")"
else
  MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
fi
export MYSQL_PWD

query() {
  mariadb --protocol=socket -uroot --batch --skip-column-names -e "$1" 2>/dev/null
}

ready="$(query "SHOW STATUS LIKE 'wsrep_ready'"       | awk '{print $2}')"
state="$(query "SHOW STATUS LIKE 'wsrep_local_state'" | awk '{print $2}')"

# 4 = Synced. 2 = Donor/Desynced: still serving, so treat as healthy.
if [ "${ready}" = "ON" ] && { [ "${state}" = "4" ] || [ "${state}" = "2" ]; }; then
  exit 0
fi

echo "unhealthy: wsrep_ready=${ready:-?} wsrep_local_state=${state:-?}" >&2
exit 1