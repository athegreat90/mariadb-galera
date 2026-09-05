# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A container image that adds Galera multi-primary clustering on top of the official
`mariadb:11.8` image. There is no application code — the repo is a `Dockerfile`, a
`rootfs/` overlay that is copied verbatim into the image, a thin entrypoint wrapper,
a healthcheck, and the CI that builds/tests/publishes the multi-arch image to GHCR.

`README.md` is the user-facing usage guide (env vars, compose cluster, recovery);
this file covers internals for contributors.

## Common commands

```bash
# Build locally (single arch, into the local daemon)
docker build -t mariadb-galera:test .

# Single-node smoke test — boots a bootstrap node, waits for HEALTHCHECK,
# asserts wsrep_cluster_size == 1. This is exactly what CI runs.
./test/smoke-test.sh mariadb-galera:test

# 3-node cluster locally: set `image:` in test/docker-compose.yml to your local
# tag first, then
docker compose -f test/docker-compose.yml up

# Lint the shell scripts (all use `set -Eeuo pipefail`; keep them shellcheck-clean)
shellcheck rootfs/usr/local/bin/*.sh test/smoke-test.sh

# Refresh the pinned base image digest (the FROM line ships a placeholder digest)
docker buildx imagetools inspect mariadb:11.8 --format '{{ .Manifest.Digest }}'
```

## Architecture

### Config layering
MariaDB reads config in filename order. Two files matter:

- `rootfs/etc/mysql/conf.d/90-galera.cnf` — static cluster-wide settings
  (`binlog_format=ROW`, `wsrep_provider`, `innodb_autoinc_lock_mode=2`, …). Its last
  line is `!includedir /etc/mysql/galera.conf.d/` and **must stay last**.
- `/etc/mysql/galera.conf.d/99-galera-runtime.cnf` — written at container start by
  the entrypoint with the per-node values (cluster name/address, node identity,
  `wsrep_sst_auth`). Not in the repo; generated every boot.

`/etc/mysql/galera.conf.d/` and `/docker-entrypoint-initdb.d/` are `chown`ed to
`mysql` in the Dockerfile because the entrypoint runs as `mysql` (not root) and
writes into both.

### Entrypoint (`rootfs/usr/local/bin/galera-entrypoint.sh`)
Runs before, and then `exec`s into, the **upstream** `/usr/local/bin/docker-entrypoint.sh`
(so all standard `MARIADB_*` / `MYSQL_*` behavior from the base image still applies).
Its own job:
1. `file_env` resolves `VAR` vs `VAR_FILE` secrets (mirrors the upstream `_FILE` convention).
2. Defaults all `MARIADB_GALERA_*` vars; auto-detects `NODE_ADDRESS` via `ip route get 1.1.1.1`.
3. Writes `99-galera-runtime.cnf` (umask 0077 for the SST password).
4. On a **fresh datadir only** (`/var/lib/mysql/mysql` absent → this is the bootstrap
   node), queues `/docker-entrypoint-initdb.d/00-galera-sst-user.sql` to create the
   mariabackup SST user. Joiners inherit that account through SST, so it is only
   created once.
5. Appends `--wsrep-new-cluster` when `MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes`, and
   forces `safe_to_bootstrap: 1` in `grastate.dat` when `..._FORCE_SAFETOBOOTSTRAP=yes`.
6. Appends word-split `MARIADB_GALERA_EXTRA_FLAGS`.

Exactly one node in a new cluster sets `CLUSTER_BOOTSTRAP=yes`; the rest join via
`MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://node1,node2,node3`.

### Healthcheck (`rootfs/usr/local/bin/galera-healthcheck.sh`)
Connects over the unix socket as root (password from
`MARIADB_ROOT_PASSWORD[_FILE]` / `MYSQL_ROOT_PASSWORD`). Healthy iff
`wsrep_ready=ON` and `wsrep_local_state` is `4` (Synced) or `2` (Donor/Desynced —
still serving). Used by both the Dockerfile `HEALTHCHECK` and the compose file, and
`depends_on: service_healthy` is what serializes node startup in the compose test.

### Base image pinning
`FROM mariadb:11.8@sha256:<digest>` is pinned by digest. Three things act on it:
- **Dependabot** (`docker` ecosystem) bumps the tag.
- **`base-image-watch.yml`** (daily cron) compares the pinned digest to the live
  `mariadb:11.8` digest; on drift it `sed`s the new digest into the `Dockerfile`,
  commits, and calls `build.yml` via `workflow_call` for that commit.
- **`build.yml`** re-parses the `FROM` line to pass `BASE_IMAGE_REF` / `BASE_IMAGE_DIGEST`
  into OCI labels.

### CI (`.github/workflows/build.yml`)
- `build` matrix: native runners per arch (`ubuntu-24.04`, `ubuntu-24.04-arm`).
  Builds with `load: true` → runs `./test/smoke-test.sh` on real hardware for that
  arch → rebuilds (cache hit) and pushes **by digest** (`push-by-digest=true`, no
  tag) with provenance + SBOM. Digests are uploaded as artifacts.
- `merge`: downloads the per-arch digests, `docker buildx imagetools create`s the
  multi-arch manifest with all tags/annotations from `docker/metadata-action`, then
  `attest-build-provenance`. Tags (`11.8`, `11.8-<timestamp>`, `latest`) only apply
  on the default branch; `v*` tags produce semver tags.
- `publish-public`: best-effort (`continue-on-error`) call to make the GHCR package
  public; uses `GHCR_ADMIN_TOKEN` if set, else `GITHUB_TOKEN`.
- PRs build + smoke-test only; nothing is pushed.

## Conventions

- Commit prefixes: `chore(docker)`, `chore(actions)` (Dependabot); `chore:` for the
  base-image bot. Keep that style.
- Shell scripts: bash with `set -Eeuo pipefail`, `log()` to stderr with a UTC
  timestamp, secrets written under `umask 0077`.
- The `test -f /usr/lib/galera/libgalera_smm.so` at the end of the Dockerfile `RUN`
  is a deliberate build-time assertion that the wsrep provider exists — don't remove it.
