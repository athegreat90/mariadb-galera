#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '%s [galera-entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

# Mirrors the upstream image's *_FILE convention for secrets.
file_env() {
  local var="$1" file_var="${1}_FILE" def="${2:-}" val=""
  if [ -n "${!var:-}" ] && [ -n "${!file_var:-}" ]; then
    log "ERROR: $var and $file_var are mutually exclusive"; exit 1
  fi
  if   [ -n "${!var:-}" ];      then val="${!var}"
  elif [ -n "${!file_var:-}" ]; then val="$(< "${!file_var}")"
  else                               val="$def"
  fi
  export "$var"="$val"
  unset "$file_var"
}

detect_ip() {
  ip -4 -o route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

file_env MARIADB_GALERA_MARIABACKUP_PASSWORD ""
file_env MARIADB_ROOT_PASSWORD "${MYSQL_ROOT_PASSWORD:-}"

: "${MARIADB_GALERA_CLUSTER_NAME:=galera}"
: "${MARIADB_GALERA_CLUSTER_ADDRESS:=gcomm://}"
: "${MARIADB_GALERA_NODE_NAME:=$(hostname)}"
: "${MARIADB_GALERA_NODE_ADDRESS:=$(detect_ip)}"
: "${MARIADB_GALERA_CLUSTER_BOOTSTRAP:=no}"
: "${MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP:=no}"
: "${MARIADB_GALERA_MARIABACKUP_USER:=mariabackup}"
: "${MARIADB_GALERA_SST_METHOD:=mariabackup}"
: "${MARIADB_GALERA_EXTRA_FLAGS:=}"
: "${MARIADB_GALERA_PROVIDER_OPTIONS:=}"
: "${MARIADB_GALERA_IST_RECV_BIND:=}"

if [ -z "${MARIADB_GALERA_NODE_ADDRESS}" ]; then
  log "ERROR: could not detect node address; set MARIADB_GALERA_NODE_ADDRESS"
  exit 1
fi

if [ "${MARIADB_GALERA_SST_METHOD}" = "mariabackup" ] \
   && [ -z "${MARIADB_GALERA_MARIABACKUP_PASSWORD}" ]; then
  log "ERROR: MARIADB_GALERA_MARIABACKUP_PASSWORD (or _FILE) is required for mariabackup SST"
  exit 1
fi

# wsrep_provider_options is a single string: a later setting (another .cnf, or a
# --wsrep-provider-options flag in EXTRA_FLAGS) replaces it rather than merging,
# so everything for it is assembled here into one line.
provider_opts=""
[ -n "${MARIADB_GALERA_IST_RECV_BIND}" ] \
  && provider_opts="ist.recv_bind=${MARIADB_GALERA_IST_RECV_BIND}"
[ -n "${MARIADB_GALERA_PROVIDER_OPTIONS}" ] \
  && provider_opts="${provider_opts:+${provider_opts}; }${MARIADB_GALERA_PROVIDER_OPTIONS}"
case "${provider_opts}" in
  *\"*) log 'ERROR: MARIADB_GALERA_PROVIDER_OPTIONS / _IST_RECV_BIND must not contain double quotes'; exit 1 ;;
esac

conf="/etc/mysql/galera.conf.d/99-galera-runtime.cnf"
umask 0077
cat > "${conf}" <<EOF
[mysqld]
wsrep_cluster_name    = ${MARIADB_GALERA_CLUSTER_NAME}
wsrep_cluster_address = ${MARIADB_GALERA_CLUSTER_ADDRESS}
wsrep_node_name       = ${MARIADB_GALERA_NODE_NAME}
wsrep_node_address    = ${MARIADB_GALERA_NODE_ADDRESS}
wsrep_sst_method      = ${MARIADB_GALERA_SST_METHOD}
wsrep_sst_auth        = ${MARIADB_GALERA_MARIABACKUP_USER}:${MARIADB_GALERA_MARIABACKUP_PASSWORD}
EOF
if [ -n "${provider_opts}" ]; then
  printf 'wsrep_provider_options = "%s"\n' "${provider_opts}" >> "${conf}"
  log "wsrep_provider_options = ${provider_opts}"
fi
umask 0022
log "wrote ${conf} (node=${MARIADB_GALERA_NODE_NAME} addr=${MARIADB_GALERA_NODE_ADDRESS})"

grastate="/var/lib/mysql/grastate.dat"
grastate_val() { sed -n "s/^$1:[[:space:]]*//p" "${grastate}" 2>/dev/null | head -n1; }
if [ -f "${grastate}" ]; then
  log "grastate: uuid=$(grastate_val uuid) seqno=$(grastate_val seqno) safe_to_bootstrap=$(grastate_val safe_to_bootstrap)"
  if [ "$(grastate_val seqno)" = "-1" ]; then
    log "previous shutdown was not clean (seqno -1). If every node is down, run galera-recover.sh on each to find the most advanced one"
  fi
fi

# Only runs on a fresh datadir, i.e. the bootstrap node. Joiners inherit the
# account through SST.
if [ ! -d /var/lib/mysql/mysql ]; then
  sst_sql="/docker-entrypoint-initdb.d/00-galera-sst-user.sql"
  umask 0077
  cat > "${sst_sql}" <<EOF
CREATE USER IF NOT EXISTS '${MARIADB_GALERA_MARIABACKUP_USER}'@'localhost'
  IDENTIFIED BY '${MARIADB_GALERA_MARIABACKUP_PASSWORD}';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR, REPLICA MONITOR,
      CONNECTION ADMIN, READ_ONLY ADMIN
  ON *.* TO '${MARIADB_GALERA_MARIABACKUP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
  umask 0022
  log "queued SST user bootstrap SQL"
fi

extra_args=()

if [ "${MARIADB_GALERA_CLUSTER_BOOTSTRAP}" = "yes" ]; then
  if [ -f "${grastate}" ]; then
    if [ "${MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP}" = "yes" ]; then
      log "forcing safe_to_bootstrap=1 in ${grastate}"
      sed -i 's/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/' "${grastate}"
    elif [ "$(grastate_val safe_to_bootstrap)" = "0" ]; then
      log "ERROR: refusing to bootstrap: ${grastate} has safe_to_bootstrap=0, so this node may not hold the latest data."
      log "  * If this is an existing cluster node, MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes is probably a stale setting:"
      log "    unset it and recreate the container (container env is frozen when the container is created)."
      log "  * If the WHOLE cluster is down, run galera-recover.sh on every node's datadir, then start the node with the"
      log "    highest seqno with MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes and MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes."
      exit 1
    else
      log "WARNING: bootstrapping on an existing datadir; remove MARIADB_GALERA_CLUSTER_BOOTSTRAP after this start so a"
      log "  later restart rejoins the cluster instead of forming a new one"
    fi
  fi
  log "bootstrapping a new cluster (--wsrep-new-cluster)"
  extra_args+=(--wsrep-new-cluster)
fi

if [ -n "${MARIADB_GALERA_EXTRA_FLAGS}" ]; then
  read -r -a user_flags <<< "${MARIADB_GALERA_EXTRA_FLAGS}"
  extra_args+=("${user_flags[@]}")
fi

exec /usr/local/bin/docker-entrypoint.sh "$@" "${extra_args[@]}"