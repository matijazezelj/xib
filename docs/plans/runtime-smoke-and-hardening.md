# XIB Runtime Smoke and Hardening Implementation Plan

**Goal:** Keep the full XIB stack testable on a Docker host and track the next hardening work found during live smoke testing.

**Architecture:** XIB remains the orchestration repo for VIB/TIB/CIB/IIB/PIB. Runtime validation lives in `scripts/smoke-test.sh` and verifies container health, Grafana provisioning, VictoriaMetrics readiness, and expected metric ingestion.

**Tech Stack:** Docker Compose, Grafana HTTP API, VictoriaMetrics HTTP API, bash, curl, Python JSON parsing.

---

## Completed in this pass

- Bumped XIB submodules to the current merged heads of `vib`, `tib`, `cib`, `iib`, and `pib`.
- Added `make smoke` for live runtime checks after `make up`.
- Verified the full stack on `root@192.168.1.67` after a clean `docker compose down -v && make up`.

## TODO: Add first-class healthchecks to all long-running services

**Why:** Runtime smoke showed most Grafana, VictoriaMetrics, and collector/scanner containers report Docker health as `none`. The services are reachable, but Docker cannot tell degraded from healthy.

**Done for `xib-grafana`** (2026-09-01): `curl` is present in `grafana/grafana:13.2.0`, so the healthcheck hits `http://localhost:3000/api/health` directly. Verified reporting `healthy` on a live container.

**Still TODO** — the five sub-project composes, which are separate repos:
- `vib/docker-compose.yml`
- `tib/docker-compose.yml`
- `cib/docker-compose.yml`
- `iib/docker-compose.yml`
- `pib/docker-compose.yml`

**Plan:**
1. Grafana: reuse the `xib-grafana` block in this repo's `docker-compose.yml`.
2. Add VictoriaMetrics healthchecks against `http://127.0.0.1:8428/health`.
3. Add collector/scanner healthchecks only if they expose a real health endpoint; otherwise do not fake it with `pgrep` nonsense.
4. Re-run `make up && make smoke`.

Note that `scripts/smoke-test.sh` now treats any container not in the `running`
state as a failure, which it previously could not see at all — it enumerated
with `docker ps`, so a crashed service was skipped rather than reported.

## TODO: Add resource/security defaults without breaking vendor images

**Why:** CIB reports missing `no-new-privileges`, CPU/memory limits, and read-only rootfs across the stack. Some vendor images need writable paths, so this needs per-image testing, not cargo-cult YAML.

**Plan:**
1. Add `security_opt: [no-new-privileges:true]` where the image still boots.
2. Add memory limits for Grafana/VictoriaMetrics/collectors.
3. Test read-only rootfs per service with required tmp/cache mounts.
4. Keep exceptions documented inline.

## TODO: Pin image versions deliberately

**Why:** The stack still uses several `:latest` tags. That is okay for early demos, but it makes runtime tests non-reproducible.

**Done for `xib-grafana`** (2026-09-01): `GRAFANA_VERSION` in `.env.example`, defaulting to `13.2.0` — which is what `grafana/grafana:latest` resolved to at the time, so this pinned current behaviour rather than changing it.

**Still TODO:**
1. Introduce `*_VERSION` variables in each sub-project `.env.example`.
2. Pin Grafana, VictoriaMetrics, Authentik, Step CA, Redis, and Postgres defaults.
3. Add Dependabot Docker updates where useful.
4. Re-run build and smoke tests on `.67`.

## Cross-repo findings

Three bugs found in the submodules on 2026-09-01 are recorded in
[submodule-findings.md](submodule-findings.md) — a LAN-exposed TIB, a label
escaper that makes VictoriaMetrics silently drop metrics, and `make up` failing
on macOS. They are not fixable from this repo.

## Verification commands

```bash
make up
make smoke
python3 scripts/validate-dashboards.py
```

Expected final line:

```text
XIB smoke test passed
```
