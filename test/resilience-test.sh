#!/usr/bin/env bash
# Reproduces the two outages seen on the live cluster and checks the image copes:
#   * provider options (IST bind / evs timeouts) reach wsrep_provider_options;
#   * every node SIGKILLed at once (seqno -1, safe_to_bootstrap 0), as after a
#     restart with too short a stop timeout;
#   * bootstrapping such a node without FORCE is refused with a clear message
#     (the stale MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes crash-loop);
#   * galera-recover.sh finds the most advanced node, which then bootstraps the
#     cluster back with the data intact;
#   * a plain `docker restart` of that bootstrapped container (frozen env still says
#     BOOTSTRAP=yes, as after a dockerd upgrade) joins the cluster instead of forming
#     a new one-node cluster, and recreating the container honors the flags again.
set -Eeuo pipefail

IMAGE="${1:?usage: resilience-test.sh IMAGE}"
ID="$$"
NET="galera-res-${ID}"
ROOT_PW=restest
SST_PW=resbackup
OPTS="evs.suspect_timeout=PT10S; evs.inactive_timeout=PT30S"
declare -A CNAME=([n1]="galera-res-${ID}-n1" [n2]="galera-res-${ID}-n2")
declare -A VOL=([n1]="galera-res-${ID}-v1" [n2]="galera-res-${ID}-v2")

log() { printf '%s [resilience-test] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
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
    -e MARIADB_GALERA_CLUSTER_NAME=res \
    -e MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://n1,n2 \
    -e MARIADB_GALERA_NODE_NAME="$n" \
    -e MARIADB_GALERA_MARIABACKUP_PASSWORD="$SST_PW" \
    -e MARIADB_GALERA_IST_RECV_BIND=0.0.0.0 \
    -e MARIADB_GALERA_PROVIDER_OPTIONS="$OPTS" \
    "$@" "$IMAGE" >/dev/null
}

recover() { # recover NODE -> "uuid=... seqno=... safe_to_bootstrap=..."
  docker run --rm --entrypoint galera-recover.sh -v "${VOL[$1]}:/var/lib/mysql" "$IMAGE" 2>/dev/null
}

docker network create "$NET" >/dev/null

log "1/7 bootstrap n1 with IST bind + evs timeouts, check they reach the provider"
start_node n1 -e MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes
wait_healthy n1
popts="$(sql n1 "SHOW VARIABLES LIKE 'wsrep_provider_options'")"
for want in 'ist.recv_bind = 0.0.0.0' 'evs.suspect_timeout = PT10S' 'evs.inactive_timeout = PT30S'; do
  grep -qF "$want" <<< "$popts" || fail "wsrep_provider_options is missing '$want'"
done

log "2/7 join n2, write a canary row"
sql n1 "CREATE DATABASE canary; CREATE TABLE canary.t (id INT PRIMARY KEY); INSERT INTO canary.t VALUES (1);"
start_node n2
wait_healthy n2
[ "$(status n2 wsrep_cluster_size)" = "2" ] || fail "expected cluster size 2 before the outage"
sql n1 "INSERT INTO canary.t VALUES (2)"
for _ in $(seq 1 10); do [ "$(sql n2 "SELECT COUNT(*) FROM canary.t")" = "2" ] && break; sleep 1; done

log "3/7 SIGKILL both nodes at once (unclean shutdown everywhere)"
docker kill "${CNAME[n1]}" "${CNAME[n2]}" >/dev/null
docker rm -f "${CNAME[n1]}" "${CNAME[n2]}" >/dev/null

log "4/7 bootstrap without FORCE must be refused with an explanation"
set +e
out="$(docker run --rm --network "$NET" --network-alias n1 -v "${VOL[n1]}:/var/lib/mysql" \
  -e MARIADB_ROOT_PASSWORD="$ROOT_PW" -e MARIADB_GALERA_CLUSTER_NAME=res \
  -e MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://n1,n2 -e MARIADB_GALERA_NODE_NAME=n1 \
  -e MARIADB_GALERA_MARIABACKUP_PASSWORD="$SST_PW" -e MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes \
  "$IMAGE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "bootstrap without FORCE on an unclean datadir was not refused"
grep -q 'refusing to bootstrap' <<< "$out" || fail "refusal message missing; got: $(tail -n 5 <<< "$out")"
grep -q 'galera-recover.sh' <<< "$out" || fail "refusal message does not mention galera-recover.sh"

log "5/7 find the most advanced node with galera-recover.sh"
r1="$(recover n1)"; r2="$(recover n2)"
log "  n1: $r1"; log "  n2: $r2"
s1="$(sed -E 's/.*seqno=(-?[0-9]+).*/\1/' <<< "$r1")"
s2="$(sed -E 's/.*seqno=(-?[0-9]+).*/\1/' <<< "$r2")"
[[ "$s1" =~ ^[0-9]+$ ]] || fail "n1 recovered seqno is not a number: '$r1'"
[[ "$s2" =~ ^[0-9]+$ ]] || fail "n2 recovered seqno is not a number: '$r2'"
best=n1; other=n2
if [ "$s2" -gt "$s1" ]; then best=n2; other=n1; fi
log "  bootstrapping from $best"

log "6/7 bootstrap $best with FORCE, rejoin $other, check the data"
start_node "$best" -e MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes -e MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes
wait_healthy "$best"
start_node "$other"
wait_healthy "$other"
[ "$(status "$other" wsrep_cluster_size)" = "2" ] || fail "cluster did not re-form with size 2"
[ "$(status "$other" wsrep_local_state_comment)" = "Synced" ] || fail "$other is not Synced"
for n in n1 n2; do
  [ "$(sql "$n" "SELECT COUNT(*) FROM canary.t")" = "2" ] || fail "canary data missing or wrong on $n after recovery"
done

log "7/7 restart $best (frozen BOOTSTRAP=yes env): must join, not bootstrap again"
out="$(docker logs "${CNAME[$best]}" 2>&1)"
boots_before="$(grep -c 'bootstrapping a new cluster' <<< "$out" || true)"
[ "$boots_before" -eq 1 ] || fail "expected exactly 1 bootstrap in the first start of $best, got $boots_before"
docker restart -t 60 "${CNAME[$best]}" >/dev/null
wait_healthy "$best"
out="$(docker logs "${CNAME[$best]}" 2>&1)"
boots_after="$(grep -c 'bootstrapping a new cluster' <<< "$out" || true)"
[ "$boots_after" -eq "$boots_before" ] || fail "$best formed a new cluster again after a plain restart ($boots_after bootstraps)"
grep -q 'bootstrap flags already used' <<< "$out" \
  || fail "$best restart did not log that the bootstrap flags were ignored"
[ "$(status "$best" wsrep_cluster_size)" = "2" ] || fail "$best did not rejoin the running cluster after the restart"
[ "$(status "$best" wsrep_local_state_comment)" = "Synced" ] || fail "$best is not Synced after the restart"

log "  recreating $best (new container) must honor the bootstrap flags again"
docker rm -f "${CNAME[$other]}" "${CNAME[$best]}" >/dev/null
start_node "$best" -e MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes -e MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes
wait_healthy "$best"
out="$(docker logs "${CNAME[$best]}" 2>&1)"
grep -q 'bootstrapping a new cluster' <<< "$out" || fail "recreated $best did not honor the bootstrap flags"
if grep -q 'bootstrap flags already used' <<< "$out"; then
  fail "recreated $best wrongly reported the bootstrap flags as already used"
fi
[ "$(sql "$best" "SELECT COUNT(*) FROM canary.t")" = "2" ] || fail "canary data missing on $best after recreate"

log "OK: options applied, unclean outage refused/recovered via galera-recover.sh with data intact, bootstrap honored once per container"
