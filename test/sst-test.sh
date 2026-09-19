#!/usr/bin/env bash
# Forced 2-node SST test: n1 bootstraps and gets data, n2 joins with an empty
# datadir, which guarantees a full mariabackup SST. Catches breakage in the SST
# user GRANTs, the wsrep SST scripts, and joiner startup that the single-node
# smoke test cannot see.
set -Eeuo pipefail

IMAGE="${1:?usage: sst-test.sh IMAGE}"
SUFFIX="$$"
NET="galera-sst-net-${SUFFIX}"
N1="galera-sst-n1-${SUFFIX}"
N2="galera-sst-n2-${SUFFIX}"
ROOT_PW="ssttest"
BACKUP_PW="sstbackup"

cleanup() {
  for c in "$N1" "$N2"; do
    echo "----- logs: $c (last 80 lines) -----" >&2
    docker logs "$c" 2>&1 | tail -n 80 >&2 || true
  done
  docker rm -f "$N1" "$N2" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

sql() { # sql CONTAINER STATEMENT
  docker exec -e MYSQL_PWD="$ROOT_PW" "$1" mariadb --protocol=socket -uroot -N -B -e "$2"
}

status() { # status CONTAINER VARIABLE
  sql "$1" "SHOW STATUS LIKE '$2'" | awk '{print $2}'
}

wait_healthy() { # wait_healthy CONTAINER
  for _ in $(seq 1 90); do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" = "healthy" ]; then
      return 0
    fi
    sleep 5
  done
  fail "$1 never became healthy"
}

start_node() { # start_node NAME [extra docker args...]
  local name="$1"; shift
  docker run -d --name "$name" --hostname "$name" --network "$NET" \
    -e MARIADB_ROOT_PASSWORD="$ROOT_PW" \
    -e MARIADB_GALERA_CLUSTER_NAME=sst \
    -e MARIADB_GALERA_CLUSTER_ADDRESS="gcomm://${N1},${N2}" \
    -e MARIADB_GALERA_NODE_NAME="$name" \
    -e MARIADB_GALERA_MARIABACKUP_PASSWORD="$BACKUP_PW" \
    "$@" "$IMAGE" >/dev/null
}

docker network create "$NET" >/dev/null

# 1. Bootstrap n1 and seed data.
start_node "$N1" -e MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes
wait_healthy "$N1"
sql "$N1" "CREATE DATABASE canary; CREATE TABLE canary.t (id INT PRIMARY KEY); INSERT INTO canary.t VALUES (1);"

# 2. Join n2 with an empty datadir => full mariabackup SST from n1.
start_node "$N2"
wait_healthy "$N2"

# 3. Cluster formed and the joiner received the data.
size="$(status "$N2" wsrep_cluster_size)"
[ "$size" = "2" ] || fail "expected wsrep_cluster_size 2 on n2, got '$size'"
state="$(status "$N2" wsrep_local_state_comment)"
[ "$state" = "Synced" ] || fail "expected n2 Synced, got '$state'"
got="$(sql "$N2" "SELECT id FROM canary.t")"
[ "$got" = "1" ] || fail "canary row not present on n2 after SST (got '$got')"

# 4. Replication works in the other direction too.
sql "$N2" "INSERT INTO canary.t VALUES (2);"
for _ in $(seq 1 12); do
  got="$(sql "$N1" "SELECT COUNT(*) FROM canary.t")"
  [ "$got" = "2" ] && break
  sleep 1
done
[ "$got" = "2" ] || fail "row written on n2 did not replicate to n1 (count '$got')"

# 5. The donor really ran mariabackup SST, and it did not report errors.
n1_log="$(docker logs "$N1" 2>&1)"
grep -q 'wsrep_sst_mariabackup' <<< "$n1_log" || fail "no wsrep_sst_mariabackup activity in n1 log; SST did not run"
if grep -qE 'SST failed|Process completed with error' <<< "$n1_log"; then
  fail "SST errors found in n1 log"
fi

provider="$(status "$N2" wsrep_provider_version)"
echo "OK: forced SST joined n2, data and bidirectional writes verified (wsrep provider ${provider})"
