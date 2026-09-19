#!/usr/bin/env bash
# Finds the position a node can recover to, so that after a full-cluster outage
# (every node left with `seqno: -1` / `safe_to_bootstrap: 0`) you can tell which
# node is the most advanced one and bootstrap from it.
#
# Run it against a STOPPED node's data directory, once per node:
#   docker run --rm --entrypoint galera-recover.sh -v <datadir>:/var/lib/mysql IMAGE
#
# It runs InnoDB crash recovery via `mariadbd --wsrep-recover` and prints one
# line on stdout:  uuid=<cluster uuid> seqno=<n> safe_to_bootstrap=<0|1|unknown>
# The node with the highest seqno is the one to start with
# MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes and MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes.
set -Eeuo pipefail

log() { printf '%s [galera-recover] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

datadir="/var/lib/mysql"
grastate="${datadir}/grastate.dat"

if [ ! -d "${datadir}/mysql" ]; then
  log "ERROR: ${datadir} has no MariaDB data; mount the node's data directory there"
  exit 1
fi

safe="unknown"
if [ -f "${grastate}" ]; then
  safe="$(sed -n 's/^safe_to_bootstrap:[[:space:]]*//p' "${grastate}" | head -n1)"
  safe="${safe:-unknown}"
fi

errlog="$(mktemp)"
trap 'rm -f "${errlog}"' EXIT

log "running mariadbd --wsrep-recover (the node must not be running on this datadir)"
# Recovery mode never joins a cluster or transfers state; the bare gcomm:// is
# only there because the mariabackup SST method refuses to start without a
# cluster address (this container has no runtime config from the entrypoint).
if ! mariadbd --wsrep-recover --wsrep-cluster-address=gcomm:// --log-error="${errlog}" >>"${errlog}" 2>&1; then
  log "ERROR: mariadbd --wsrep-recover failed; last lines of its log:"
  tail -n 20 "${errlog}" >&2 || true
  exit 1
fi

position="$(sed -n 's/.*WSREP: Recovered position:[[:space:]]*//p' "${errlog}" | tail -n1)"
if [ -z "${position}" ]; then
  log "ERROR: no recovered position found; last lines of the log:"
  tail -n 20 "${errlog}" >&2 || true
  exit 1
fi

uuid="${position%:*}"
seqno="${position##*:}"
log "recovered position ${position}"
printf 'uuid=%s seqno=%s safe_to_bootstrap=%s\n' "${uuid}" "${seqno}" "${safe}"
