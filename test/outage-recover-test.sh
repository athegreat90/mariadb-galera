#!/usr/bin/env bash
# Full-cluster outage: every node SIGKILLed (seqno -1, safe_to_bootstrap 0), then all
# restarted with BOOTSTRAP=no. Checks the image does the safe part automatically and
# nothing more:
#   * each node recovers its position and logs one parseable line
#     "recovered position <uuid>:<seqno>";
#   * the logged position matches what galera-recover.sh reports for the same datadir;
#   * no node bootstraps itself (no --wsrep-new-cluster, no cluster ever becomes
#     Primary) and safe_to_bootstrap stays 0 on every datadir.
set -Eeuo pipefail

IMAGE="${1:?usage: outage-recover-test.sh IMAGE}"
ID="$$"
NET="galera-out-${ID}"
ROOT_PW=outtest
SST_PW=outbackup
declare -A CNAME=([n1]="galera-out-${ID}-n1" [n2]="galera-out-${ID}-n2")
declare -A VOL=([n1]="galera-out-${ID}-v1" [n2]="galera-out-${ID}-v2")
POS_RE='recovered position [0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}:[0-9]+'

log() { printf '%s [outage-recover-test] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

cleanup() {
  local rc=$? n
  for n in n1 n2; do
    if [ "$rc" -ne 0 ] && docker inspect "${CNAME[$n]}" >/dev/null 2>&1; then
      echo "=== logs: ${CNAME[$n]} ===" >&2
      docker logs "${CNAME[$n]}" 2>&1 | tail -n 60 >&2 || true
    fi
    docker rm -f "${CNAME[$n]}" >/dev/null 2>&1 || true
    docker volume rm "${VOL[$n]}" >/dev/null 2>&1 || true
  done
  docker network rm "$NET" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

sql() { # sql NODE STATEMENT
  docker exec -e MYSQL_PWD="$ROOT_PW" "${CNAME[$1]}" mariadb --protocol=socket -uroot -N -B -e "$2"
}
status() { sql "$1" "SHOW STATUS LIKE '$2'" | awk '{print $2}'; }

wait_healthy() {
  for _ in $(seq 1 90); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "${CNAME[$1]}")" = "healthy" ] && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "${CNAME[$1]}")" = "true" ] || fail "$1 exited"
    sleep 5
  done
  fail "$1 never became healthy"
}

start_node() { # start_node NODE [extra docker args...]
  local n="$1"; shift
  docker run -d --name "${CNAME[$n]}" --network "$NET" --network-alias "$n" \
    -v "${VOL[$n]}:/var/lib/mysql" \
    -e MARIADB_ROOT_PASSWORD="$ROOT_PW" \
    -e MARIADB_GALERA_CLUSTER_NAME=out \
    -e MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://n1,n2 \
    -e MARIADB_GALERA_NODE_NAME="$n" \
    -e MARIADB_GALERA_MARIABACKUP_PASSWORD="$SST_PW" \
    "$@" "$IMAGE" >/dev/null
}

recover() { # recover NODE -> "uuid=... seqno=... safe_to_bootstrap=..." (node must be stopped)
  docker run --rm --entrypoint galera-recover.sh -v "${VOL[$1]}:/var/lib/mysql" "$IMAGE" 2>/dev/null
}

grastate_safe() { # grastate_safe NODE -> safe_to_bootstrap value (node must be stopped)
  docker run --rm --entrypoint sh -v "${VOL[$1]}:/var/lib/mysql" "$IMAGE" \
    -c "sed -n 's/^safe_to_bootstrap:[[:space:]]*//p' /var/lib/mysql/grastate.dat"
}

docker network create "$NET" >/dev/null

log "1/6 bootstrap n1, join n2, write canary rows"
start_node n1 -e MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes
wait_healthy n1
sql n1 "CREATE DATABASE canary; CREATE TABLE canary.t (id INT PRIMARY KEY); INSERT INTO canary.t VALUES (1);"
start_node n2
wait_healthy n2
[ "$(status n2 wsrep_cluster_size)" = "2" ] || fail "expected cluster size 2 before the outage"
sql n1 "INSERT INTO canary.t VALUES (2)"
for _ in $(seq 1 10); do [ "$(sql n2 "SELECT COUNT(*) FROM canary.t")" = "2" ] && break; sleep 1; done

log "2/6 SIGKILL both nodes at once (full-cluster outage)"
docker kill "${CNAME[n1]}" "${CNAME[n2]}" >/dev/null
docker rm -f "${CNAME[n1]}" "${CNAME[n2]}" >/dev/null

# pc.recovery (default on) re-forms the Primary component by itself when every member of
# the last one comes back together, which would hide the scenario under test. Switch it off
# on the restart to reproduce the real outage: nodes that cannot agree on a Primary.
log "3/6 restart both with BOOTSTRAP=no and pc.recovery off (nodes cannot re-form a Primary alone)"
start_node n1 -e MARIADB_GALERA_PROVIDER_OPTIONS=pc.recovery=false
start_node n2 -e MARIADB_GALERA_PROVIDER_OPTIONS=pc.recovery=false

log "4/6 each node must log a parseable recovered position"
declare -A POS
for n in n1 n2; do
  line=""
  for _ in $(seq 1 60); do
    line="$(docker logs "${CNAME[$n]}" 2>&1 | grep -oE "$POS_RE" | head -n1 || true)"
    [ -n "$line" ] && break
    sleep 3
  done
  [ -n "$line" ] || fail "$n never logged a 'recovered position <uuid>:<seqno>' line"
  POS[$n]="${line#recovered position }"
  log "  $n: ${POS[$n]}"
done

log "5/6 no node may bootstrap itself or become Primary"
sleep 45
for n in n1 n2; do
  out="$(docker logs "${CNAME[$n]}" 2>&1)"
  if grep -qE 'bootstrapping a new cluster|--wsrep-new-cluster' <<< "$out"; then
    fail "$n bootstrapped itself"
  fi
  [ "$(docker inspect -f '{{.State.Health.Status}}' "${CNAME[$n]}")" != "healthy" ] \
    || fail "$n became healthy without an operator bootstrapping the cluster"
  if [ "$(docker inspect -f '{{.State.Running}}' "${CNAME[$n]}")" = "true" ]; then
    st="$(status "$n" wsrep_cluster_status 2>/dev/null || true)"
    [ "$st" != "Primary" ] || fail "$n reports a Primary component without a bootstrap"
  fi
done

log "6/6 logged positions match galera-recover.sh and safe_to_bootstrap is untouched"
docker rm -f "${CNAME[n1]}" "${CNAME[n2]}" >/dev/null
for n in n1 n2; do
  r="$(recover "$n")"
  want="$(sed -E 's/^uuid=([^ ]+) seqno=(-?[0-9]+).*/\1:\2/' <<< "$r")"
  [ "$want" = "${POS[$n]}" ] || fail "$n logged '${POS[$n]}' but galera-recover.sh reports '$want'"
  [ "$(grastate_safe "$n")" = "0" ] || fail "$n safe_to_bootstrap was changed on the automatic path"
done

log "OK: every node recovered and logged its position after a full outage; none bootstrapped itself"
