# outage-auto-recover

Branch: `feat/outage-auto-recover` (from origin/main fe8315f). Plan: `~/.claude/plans/humming-cuddling-elephant.md`.
Engram mirror: `odd/outage-auto-recover/tasks` (pending: Engram `mem_save` failed earlier this session).

## Objective
After a full-cluster outage (all nodes `seqno=-1`, `safe_to_bootstrap=0`), make recovery fast and safe without any node bootstrapping itself.

## Problem
2026-10-30: a8 lost power hard, all three nodes restarted non-primary, and the image only logged a hint (`galera-entrypoint.sh:81-88`). Manual `galera-recover.sh` plus a manual bootstrap was needed.

## Scope (authorized)
Only: `rootfs/usr/local/bin/galera-entrypoint.sh`, `scripts/galera-full-outage-recover.sh` (new), `test/outage-recover-test.sh` (new), `test/docker-compose.yml`, `.github/workflows/build.yml`, `README.md`. Out of scope: any in-image auto-bootstrap, `safe_to_bootstrap` changes, the bootstrap-once guard.

## Constraints
- Never add `--wsrep-new-cluster` automatically; never touch `safe_to_bootstrap` on the auto path.
- Scripts: `set -Eeuo pipefail`, `log()` with UTC timestamps to stderr, shellcheck-clean.
- Conventional Commits, no AI attribution. No push/PR/merge without the user.
- ~400 changed lines per task is a planning heuristic only.

## Tasks
- [x] T1 entrypoint: on `seqno=-1`, run recovery, log one parseable `recovered position uuid:seqno` line; test-first via T2.
- [x] T2 `test/outage-recover-test.sh`: SIGKILL all nodes, restart BOOTSTRAP=no, assert non-primary, recovered-position line logged, no self-bootstrap; wire into `build.yml`; add `stop_grace_period: 60s` to `test/docker-compose.yml`.
- [x] T3 `scripts/galera-full-outage-recover.sh`: read positions, refuse on unreachable/unreadable unless `--force` + explicit list, pick highest seqno, confirm before bootstrap.
- [x] T4 `README.md`: log line, script, grace-period advice.
- [x] T5 rollout (needs explicit go-ahead): fresh backup, pi5 -> a8 -> Home Assistant add-on, verify size 3 Synced.

## Acceptance
shellcheck + hadolint clean; new test passes with smoke, SST and resilience tests on 11.8 and 12.3; after rollout `wsrep_cluster_size=3`, Primary, gotify row counts unchanged.

## Routing
T1-T4: delegated direct, one writer (4+ non-trivial files; mapping done by explorer). T5: inline, user-gated.

## Progress / evidence
- T2 c35a6de (test), T1 b8a6805 (entrypoint; also carries the final pc.recovery=false tweak to the test), T3 3b45844 (script), T4 88b4760 (docs). Route: delegated direct (one writer).
- RED: test against the unmodified entrypoint (12.3) failed at step 4: `n1 never logged a 'recovered position <uuid>:<seqno>' line`.
- GREEN: test passes on 12.3 and 11.8 after the entrypoint change; smoke, resilience and sst tests pass on 12.3.
- Finding: with default pc.recovery=true both SIGKILLed nodes restarted together re-form a Primary alone (gvwstate.dat), so the test restarts them with `pc.recovery=false` to reproduce the real non-primary outage.
- shellcheck (koalaman/shellcheck:stable) clean on the entrypoint, the new test and the new script. Script exercised with a stub `docker` (readable, unreadable refusal, --force, --yes, no-tty refusal).
- hadolint and CI: PR #15 CI green (lint, secrets, image-scan, 4 build legs), squash-merged as 9c8a53a; the `main` build published `:lts` with the change.
- T5 (inline, user-authorized 2026-10-30): fresh backup on a8 (`backups/20261030-133147`), then pi5, a8 and the Home Assistant add-on (`ha addons rebuild local_mariadb_galera_node`), one at a time. After each step: `wsrep_cluster_size=3`, Primary, Synced. Gotify row counts unchanged (messages 1049, clients 4, applications 3, users 1, plugin_confs 0).
- Not confirmed: whether the Home Assistant rebuild pulled the new base image (local add-on, Dockerfile not visible from the SSH add-on).
- Engram mirror `odd/outage-auto-recover/tasks` is still pending: `mem_save` failed with a session-registration error.

## Next step
None for this feature. Optionally confirm the Home Assistant add-on's base image.
