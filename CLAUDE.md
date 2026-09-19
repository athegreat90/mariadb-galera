# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A container image that adds Galera multi-primary clustering on top of the official
`mariadb` image. It is built and published for **two LTS series in parallel** — the
current LTS (`12.3`, tracked by `:latest` / `:lts`) and the previous LTS (`11.8`, kept
until upstream EOL). There is no application code — the repo is a `Dockerfile`, a
`rootfs/` overlay that is copied verbatim into the image, a thin entrypoint wrapper,
a healthcheck, and the CI that builds/tests/publishes the multi-arch images to GHCR.

`README.md` is the user-facing usage guide (env vars, compose cluster, recovery);
this file covers internals for contributors.

## Common commands

```bash
# Build locally (single arch, into the local daemon). A bare build uses the
# Dockerfile's default BASE_IMAGE (the current LTS); to build a specific series
# exactly as CI does, pass the pin from .github/base-images.json:
docker build -t mariadb-galera:test .
docker build -t mariadb-galera:test-11.8 \
  --build-arg BASE_IMAGE=docker.io/library/mariadb:11.8@sha256:<digest> \
  --build-arg BASE_IMAGE_REF=docker.io/library/mariadb:11.8 \
  --build-arg BASE_IMAGE_DIGEST=sha256:<digest> .

# Single-node smoke test — boots a bootstrap node, waits for HEALTHCHECK,
# asserts wsrep_cluster_size == 1. CI runs this on every series x arch leg.
./test/smoke-test.sh mariadb-galera:test

# Forced 2-node SST test — n2 joins with an empty datadir, so a full mariabackup
# SST must succeed (exercises the SST-user GRANTs and the wsrep SST scripts).
# CI runs this too, right after the smoke test.
./test/sst-test.sh mariadb-galera:test

# Outage-recovery test — SIGKILLs both nodes (as in the 2026-09-15 quorum loss), checks
# the bootstrap guard, recovers with galera-recover.sh, and checks the provider-options
# env vars. CI runs this after the SST test.
./test/resilience-test.sh mariadb-galera:test

# 3-node cluster locally (defaults to ghcr.io/athegreat90/mariadb-galera:lts;
# override with TAG=11.8, or edit `image:` to use a local tag)
docker compose -f test/docker-compose.yml up

# Lint the shell scripts (all use `set -Eeuo pipefail`; keep them shellcheck-clean)
shellcheck rootfs/usr/local/bin/*.sh test/*.sh

# Resolve a series' current upstream digest (what base-image-watch.yml writes to
# .github/base-images.json)
docker buildx imagetools inspect docker.io/library/mariadb:12.3 --format '{{ .Manifest.Digest }}'
```

On Windows, `.gitattributes` forces LF for scripts, the Dockerfile and `rootfs/`
(with `core.autocrlf=true` a CRLF checkout gets copied into the image and the
entrypoint dies with `bash\r: No such file or directory`).

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
3. Writes `99-galera-runtime.cnf` (umask 0077 for the SST password). It also assembles
   the one `wsrep_provider_options` line from `MARIADB_GALERA_IST_RECV_BIND` and
   `MARIADB_GALERA_PROVIDER_OPTIONS`; that variable is a single string, so a later
   setting (another `.cnf`, or `--wsrep-provider-options` in `EXTRA_FLAGS`) *replaces* it
   instead of merging. Then logs `grastate.dat` (uuid/seqno/safe_to_bootstrap) and flags
   an unclean shutdown (`seqno -1`).
4. On a **fresh datadir only** (`/var/lib/mysql/mysql` absent → this is the bootstrap
   node), queues `/docker-entrypoint-initdb.d/00-galera-sst-user.sql` to create the
   mariabackup SST user. Joiners inherit that account through SST, so it is only
   created once.
5. Appends `--wsrep-new-cluster` when `MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes`, and
   forces `safe_to_bootstrap: 1` in `grastate.dat` when `..._FORCE_SAFETOBOOTSTRAP=yes`.
   Guard: with BOOTSTRAP=yes on an existing datadir whose `grastate.dat` says
   `safe_to_bootstrap: 0` and no FORCE, it exits 1 with an explanation (a stale BOOTSTRAP
   env — container env is frozen at create time — or a full-cluster outage) instead of
   letting Galera abort cryptically. With `safe_to_bootstrap: 1` it warns to remove the flag.
6. Appends word-split `MARIADB_GALERA_EXTRA_FLAGS`.

`galera-recover.sh` (same directory) is run by hand against a *stopped* node's datadir
(`docker run --rm --entrypoint galera-recover.sh -v <data>:/var/lib/mysql IMAGE`). It runs
`mariadbd --wsrep-recover` and prints `uuid=… seqno=… safe_to_bootstrap=…`; the highest
seqno is the node to bootstrap after a full outage.

Exactly one node in a new cluster sets `CLUSTER_BOOTSTRAP=yes`; the rest join via
`MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://node1,node2,node3`.

### Healthcheck (`rootfs/usr/local/bin/galera-healthcheck.sh`)
Connects over the unix socket as root (password from
`MARIADB_ROOT_PASSWORD[_FILE]` / `MYSQL_ROOT_PASSWORD`). Healthy iff
`wsrep_ready=ON` and `wsrep_local_state` is `4` (Synced) or `2` (Donor/Desynced —
still serving). Used by both the Dockerfile `HEALTHCHECK` and the compose file, and
`depends_on: service_healthy` is what serializes node startup in the compose test.

### Galera packaging per series
MariaDB 12.3 unbundled the Galera server hooks into a `mariadb-server-galera`
package; 11.8 has no such package. The Dockerfile installs it only when
`apt-cache show mariadb-server-galera` finds it, alongside `galera-4` (provider
`26.4.x`, wsrep API 26 on both series, so a mixed 11.8/12.3 cluster replicates).

### Base image pinning
`.github/base-images.json` is the single source of truth for base images:

```json
{ "latest_lts": "12.3",
  "series": { "<series>": { "ref": "docker.io/library/mariadb:<series>",
                            "digest": "sha256:…", "note": "…" } } }
```

`latest_lts` must be one of the `series` keys; it decides which series gets the
`:latest` and `:lts` tags. There is no `FROM <literal>` in the `Dockerfile` — it is
`ARG BASE_IMAGE` (default: the current LTS, so a bare `docker build .` works) and CI
passes `BASE_IMAGE=<ref>@<digest>`. Two things act on the JSON:
- **`base-image-watch.yml`** (daily cron) loops every series, compares the pinned
  digest to the live one, rewrites the JSON with `jq` for those that moved, commits
  (`chore: bump MariaDB base image digest(s) [<series>]`) and calls `build.yml` via
  `workflow_call` with `ref` and `series` so only the moved series rebuilds.
- **`build.yml`** feeds `ref` / `digest` from the JSON into the build and the OCI
  `base.name` / `base.digest` labels.

Dependabot's `docker` ecosystem is intentionally **not** used (it would edit a
`FROM` line that no longer exists); only `github-actions` remains.

### CI (`.github/workflows/build.yml`)
- `setup`: reads `base-images.json` and emits the series × arch matrix, `series_list`
  and `latest_lts`. The optional `series` input (comma-separated, empty = all, on
  `workflow_dispatch` / `workflow_call`) restricts the run.
- `build` matrix (series × arch, 4 legs): native runners per arch (`ubuntu-24.04`,
  `ubuntu-24.04-arm`). Builds with `load: true` → asserts the image's real
  `mariadbd --version` series equals the matrix series (catches a JSON pin pointing at
  the wrong tag) → runs `./test/smoke-test.sh`, `./test/sst-test.sh` and
  `./test/resilience-test.sh` on real
  hardware → rebuilds (cache hit, scope `<series>-<arch>`) and pushes **by digest**
  (`push-by-digest=true`, no tag) with provenance + SBOM. Uploads
  `digest-<series>-<arch>` artifacts, plus (amd64 only) `version-<series>` carrying the
  full version to `merge` (matrix jobs cannot share job outputs).
- `merge` (one per series): downloads that series' digests + version,
  `docker buildx imagetools create`s the multi-arch manifest with all tags/annotations
  from `docker/metadata-action`, then `attest-build-provenance`. Tags: `<series>`,
  `<version>`, `<version>-<timestamp>`, `sha-<git-sha>-<series>`, and — only for the
  `latest_lts` series — `latest` and `lts`. They apply only on the default branch or
  `v*` tags.
- `publish-public`: best-effort (`continue-on-error`) call to make the GHCR package
  public; uses `GHCR_ADMIN_TOKEN` if set, else `GITHUB_TOKEN`.
- PRs build + smoke/SST-test all four legs; nothing is pushed.

### Adding / retiring a MariaDB series
- **Add** (e.g. a new LTS `13.x`): add a `series` entry to `base-images.json` with the
  resolved digest; if it becomes the newest LTS, move `latest_lts` to it (the old
  series keeps its `<series>` tags but loses `:latest` / `:lts` on the next build).
  Check the PR's 4 new legs pass (the package split and SST GRANTs are the usual
  breakages), and update the README tag table.
- **Retire** (upstream EOL): delete its `series` entry (never the one named by
  `latest_lts`). Already-published tags stay in GHCR but stop being rebuilt; say so in
  the README.
- The 11.8 series is maintained until upstream EOL (2028-06); 12.3 until ~2029-06.

## Conventions

- Commit prefixes: `chore(actions)` (Dependabot); `chore:` for the base-image bot.
  Keep that style.
- Shell scripts: bash with `set -Eeuo pipefail`, `log()` to stderr with a UTC
  timestamp, secrets written under `umask 0077`.
- The `test -f /usr/lib/galera/libgalera_smm.so` at the end of the Dockerfile `RUN`
  is a deliberate build-time assertion that the wsrep provider exists — don't remove it.
- **Security guards (keep them):** `rootfs/usr/local/bin/gosu` is a `setpriv` wrapper that
  replaces the upstream image's Go `gosu` binary (its bundled Go stdlib carries dozens of
  CVEs); the Dockerfile deletes the original in its own layer (scanners still report a file
  that is only overwritten) and fails the build if `gosu` is not a script. Every GitHub
  Action is pinned to a full commit SHA with the tag in a trailing comment; Dependabot's
  `github-actions` ecosystem keeps them current, and the repo enforces SHA pinning. Workflows
  set `permissions: {}` at the top and grant per job.
- `.github/workflows/security.yml` (PRs, pushes to main, weekly) runs shellcheck, hadolint,
  actionlint, gitleaks and a Trivy scan of each series' image; a fixable CRITICAL fails it.
  Its scanner images are pinned by digest and are bumped by hand.
