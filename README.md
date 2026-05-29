# XIB — Security in a Box

Umbrella project that composes all **in-a-box** security tools into a single stack with a unified Grafana posture dashboard.

```
make up
```

That's it. All five tools start up, secrets are auto-generated on first run, and the cross-project dashboard is available at http://localhost:3000.

---

## Architecture

```
xib/
├── vib/   ← Vulnerability in a Box  (Trivy scanner + CVE metrics)
├── tib/   ← Threat Intel in a Box   (CISA KEV + EPSS cross-reference)
├── cib/   ← Compliance in a Box     (SBOM, license, EOL, container policy)
├── iib/   ← Identity in a Box       (Authentik IdP, login metrics)
├── pib/   ← PKI in a Box            (step-ca, TLS cert expiry monitor)
└── ...    ← XIB Grafana (unified dashboard, all 5 datasources)
```

Each sub-project is a git submodule with its own independent `docker compose up` — XIB orchestrates them all via Docker Compose v2 `include:` directives and connects the unified Grafana to each tool's VictoriaMetrics instance.

---

## Quick start

```bash
git clone --recurse-submodules git@github.com:matijazezelj/xib.git
cd xib
make up
```

If you already cloned without `--recurse-submodules`:
```bash
make pull-submodules
make up
```

Open **http://localhost:3000** — the XIB Security Overview dashboard loads automatically.

Each tool also has its own Grafana at its assigned port:

| Tool | Grafana | Authentik / step-ca |
|------|---------|---------------------|
| VIB — Vulnerabilities | :3001 | — |
| TIB — Threat Intel | :3002 | — |
| CIB — Compliance | :3003 | — |
| IIB — Identity | :3004 | :9080 |
| PIB — PKI | :3005 | :9000 (step-ca) |
| **XIB — Unified** | **:3000** | — |

---

## Configuration

Sub-project `.env` files are created automatically from their `.env.example` templates on first `make up`. Secrets (Authentik keys, tokens, passwords) are auto-generated.

To customise the unified Grafana:

```bash
cp .env.example .env
# Edit XIB_GRAFANA_PASSWORD
make up
```

---

## Unified dashboard

The **XIB Security Overview** (`uid: xib-overview`) aggregates data from all five tools:

**Vulnerabilities & Threat Intel** (VIB + TIB)
- Critical / High CVE counts
- CVEs matched in CISA KEV catalog
- CVEs over time by severity

**Compliance** (CIB)
- Container policy violations
- License violations
- EOL components
- Containers checked

**Identity & PKI** (IIB + PIB)
- Active users, login failures
- Certs expiring within 30 days, expired certs
- Cert days remaining over time
- Login events over time

**Sync Status**
- Last sync timestamp for all five tools

---

## Makefile targets

| Target | Description |
|--------|-------------|
| `make up` | Start the full stack (runs setup first) |
| `make down` | Stop the full stack |
| `make restart` | Restart all services |
| `make build` | Rebuild all custom images |
| `make logs` | Follow all service logs |
| `make setup` | Create sub-project .env files and generate secrets |
| `make update` | Pull latest commits on all submodules |
| `make pull-submodules` | Init/clone submodules (for repos checked out without --recurse-submodules) |
| `make clean` | Stop everything and delete all volumes |

---

## Updating sub-projects

Each sub-project is pinned to a specific commit. To move all submodules to their latest `master`:

```bash
make update
make up
```

To update a single sub-project:
```bash
git submodule update --remote --merge vib
```

---

## Running tools standalone

Every sub-project is independently deployable:

```bash
cd vib
make up
```

XIB adds no dependencies to the individual tools — they function identically with or without the umbrella.
