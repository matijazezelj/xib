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

**Files:**
- `vib/docker-compose.yml`
- `tib/docker-compose.yml`
- `cib/docker-compose.yml`
- `iib/docker-compose.yml`
- `pib/docker-compose.yml`
- `docker-compose.yml` for `xib-grafana`

**Plan:**
1. Add `healthcheck` blocks for Grafana using `grafana cli` or the HTTP tool actually present in the image.
2. Add VictoriaMetrics healthchecks against `http://127.0.0.1:8428/health`.
3. Add collector/scanner healthchecks only if they expose a real health endpoint; otherwise do not fake it with `pgrep` nonsense.
4. Re-run `make up && make smoke`.

## TODO: Add resource/security defaults without breaking vendor images

**Why:** CIB reports missing `no-new-privileges`, CPU/memory limits, and read-only rootfs across the stack. Some vendor images need writable paths, so this needs per-image testing, not cargo-cult YAML.

**Plan:**
1. Add `security_opt: [no-new-privileges:true]` where the image still boots.
2. Add memory limits for Grafana/VictoriaMetrics/collectors.
3. Test read-only rootfs per service with required tmp/cache mounts.
4. Keep exceptions documented inline.

## TODO: Pin image versions deliberately

**Why:** The stack still uses several `:latest` tags. That is okay for early demos, but it makes runtime tests non-reproducible.

**Plan:**
1. Introduce `*_VERSION` variables in each `.env.example`.
2. Pin Grafana, VictoriaMetrics, Authentik, Step CA, Redis, and Postgres defaults.
3. Add Dependabot Docker updates where useful.
4. Re-run build and smoke tests on `.67`.

## Verification commands

```bash
make up
make smoke
```

Expected final line:

```text
XIB smoke test passed
```
