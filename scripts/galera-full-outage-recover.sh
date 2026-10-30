#!/usr/bin/env bash
# Host-side helper for a FULL Galera cluster outage (every node left with seqno -1 and
# safe_to_bootstrap 0). After the nodes restart, the image logs each node's recovered
# position ("recovered position <uuid>:<seqno>") but never bootstraps by itself. This
# script reads those positions, picks the most advanced node, prints the plan and, only
# after you confirm, bootstraps that one node.
#
# usage: galera-full-outage-recover.sh [options] NODE [NODE...]
#   NODE   HOST:CONTAINER  - HOST is an ssh destination (as in ~/.ssh/config), or the
#                            literal `local` for a container on this machine.
#   --bootstrap-cmd CMD    command that recreates the winning node's container with the
#                          bootstrap flags. It runs on the winner (over ssh unless `local`)
#                          with MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes and
#                          MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes in its environment,
#                          e.g. 'cd /srv/galera && docker compose up -d --force-recreate node'
#                          (the compose file must pass those two variables through).
#                          Without it the script only prints the plan.
#   --yes                  skip the interactive confirmation
#   --force                carry on when a node is unreachable or its position cannot be
#                          read, or the nodes disagree on the cluster uuid. DANGEROUS:
#                          the winner may not hold the newest data.
#   -h, --help             show this help
#
# Nodes are always given explicitly; hosts and credentials are never assumed. ssh runs
# with BatchMode (keys/agent only, no password prompts).
set -Eeuo pipefail

log() { printf '%s [galera-full-outage-recover] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() { sed -n '2,/^set -Eeuo/p' "${BASH_SOURCE[0]}" | sed -e '/^set -Eeuo/d' -e 's/^# \{0,1\}//' >&2; }

assume_yes=no
force=no
bootstrap_cmd=""
nodes=()

while [ $# -gt 0 ]; do
  case "$1" in
    --yes)           assume_yes=yes ;;
    --force)         force=yes ;;
    --bootstrap-cmd) [ $# -ge 2 ] || die "--bootstrap-cmd needs a value"; bootstrap_cmd="$2"; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; nodes+=("$@"); break ;;
    -*)              usage; die "unknown option: $1" ;;
    *)               nodes+=("$1") ;;
  esac
  shift
done

[ "${#nodes[@]}" -ge 1 ] || { usage; die "pass the full, explicit node list (HOST:CONTAINER ...)"; }
if [ "${#nodes[@]}" -lt 2 ] && [ "${force}" != "yes" ]; then
  die "only one node given; a full-outage recovery compares every node (use --force to proceed anyway)"
fi

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)

# run_on HOST CMD... : run a command on HOST (ssh) or locally.
run_on() {
  local host="$1"; shift
  if [ "${host}" = "local" ]; then
    "$@"
  else
    ssh "${ssh_opts[@]}" -- "${host}" "$(printf '%q ' "$@")"
  fi
}

declare -A host_of ctr_of pos_of
problems=0
valid=()
for spec in "${nodes[@]}"; do
  [[ "${spec}" == *:* ]] || die "bad node '${spec}': expected HOST:CONTAINER"
  host="${spec%:*}"; ctr="${spec##*:}"
  [ -n "${host}" ] && [ -n "${ctr}" ] || die "bad node '${spec}': expected HOST:CONTAINER"
  host_of[${spec}]="${host}"; ctr_of[${spec}]="${ctr}"

  if ! logs="$(run_on "${host}" docker logs --tail 5000 "${ctr}" 2>&1)"; then
    log "UNREACHABLE: ${spec} (ssh or docker logs failed)"
    problems=$((problems + 1)); continue
  fi
  line="$(grep -oE 'recovered position [0-9a-fA-F-]{36}:-?[0-9]+' <<< "${logs}" | tail -n1 || true)"
  p="${line#recovered position }"
  if [ -z "${line}" ] || [[ "${p##*:}" == -* ]]; then
    log "UNREADABLE: ${spec} has no usable 'recovered position' line in its logs (is it running the new image, and did recovery succeed?)"
    problems=$((problems + 1)); continue
  fi
  pos_of[${spec}]="${p}"
  valid+=("${spec}")
  log "  ${spec}: ${p}"
done

if [ "${problems}" -gt 0 ]; then
  if [ "${force}" != "yes" ]; then
    die "${problems} node(s) unreachable or unreadable; refusing to pick a bootstrap node blind. Fix them, or re-run with --force and the explicit list to accept the risk."
  fi
  log "WARNING: --force: continuing without ${problems} node(s); the winner may NOT hold the newest data"
fi
[ "${#valid[@]}" -ge 1 ] || die "no node reported a readable position"

uuids="$(for s in "${valid[@]}"; do printf '%s\n' "${pos_of[${s}]%:*}"; done | sort -u | wc -l)"
if [ "${uuids}" -gt 1 ]; then
  [ "${force}" = "yes" ] || die "nodes report different cluster uuids; they do not belong to the same cluster (--force to override)"
  log "WARNING: --force: nodes report different cluster uuids"
fi

best=""; best_seq=-1
for s in "${valid[@]}"; do
  seq="${pos_of[${s}]##*:}"
  if [ "${seq}" -gt "${best_seq}" ]; then best="${s}"; best_seq="${seq}"; fi
done
ties=0
for s in "${valid[@]}"; do [ "${pos_of[${s}]##*:}" = "${best_seq}" ] && ties=$((ties + 1)); done

log "plan: bootstrap ${best} (seqno ${best_seq}), then start the other nodes normally so they SST/IST from it"
[ "${ties}" -le 1 ] || log "  note: ${ties} nodes tie on seqno ${best_seq}; the first listed was picked and any of them is safe"

if [ -z "${bootstrap_cmd}" ]; then
  log "no --bootstrap-cmd given: nothing was changed. Recreate ${ctr_of[${best}]} on ${host_of[${best}]} with"
  log "  MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes and MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes, then start the rest."
  exit 0
fi

if [ "${assume_yes}" != "yes" ]; then
  [ -t 0 ] || die "no terminal to confirm on; re-run interactively or pass --yes"
  printf 'Bootstrap %s with command: %s\nType "yes" to continue: ' "${best}" "${bootstrap_cmd}" >&2
  read -r answer
  [ "${answer}" = "yes" ] || die "not confirmed; nothing was changed"
fi

log "bootstrapping ${best}"
run_on "${host_of[${best}]}" env MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes \
  sh -c "${bootstrap_cmd}"
log "bootstrap command finished. Wait for ${best} to be healthy (wsrep_cluster_status=Primary), then start the other nodes."
log "afterwards remove the two bootstrap variables and recreate ${best} so a later restart rejoins instead of forking."
