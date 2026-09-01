# Findings that belong in the sub-project repos

Found while auditing the XIB umbrella on 2026-09-01. Each lives in a submodule
rather than in `xib`. All three were reproduced, not inferred.

**Status:** all three are fixed. TIB's is merged and this repo's pointer is
bumped to it. IIB's two are in
[matijazezelj/iib#2](https://github.com/matijazezelj/iib/pull/2); bump the
`iib` pointer once that merges.

---

## 1. TIB publishes two ports on 0.0.0.0 — `tib` — **fixed, pointer bumped**

`tib/docker-compose.yml` lines 22 and 37 publish without a bind address:

```yaml
- "${VICTORIAMETRICS_PORT:-8430}:8428"
- "${GRAFANA_PORT:-3002}:3000"
```

Every other tool uses `"${BIND_ADDR:-127.0.0.1}:${PORT}:..."` and ships
`BIND_ADDR=127.0.0.1` in its `.env.example`; `tib` has neither. In the merged
umbrella model these are the only 2 of 14 published ports bound to all
interfaces, so `tib-victoriametrics` (unauthenticated, and writable through
`/api/v1/import`) and `tib-grafana` are reachable from the LAN while the rest of
the stack is loopback-only.

Confirmed independently from the `tib` side: `docker ps` showed
`0.0.0.0:8430->8428`, and a curl from that host's LAN address returned HTTP 200
against unauthenticated VictoriaMetrics.

Fixed in `tib` as `0d55328`, which adds the `BIND_ADDR` prefix to both ports and
a `BIND_ADDR` block to its `.env.example`. This repo's pointer is bumped to it,
and `scripts/check-port-bindings.py` now reports 14 published ports all with an
explicit host IP.

---

## 2. `_safe_label` escapes in the wrong order — `iib` — **fix open in iib#2**

`iib/monitor/monitor.py:122`:

```python
return str(s).replace('"', '\\"').replace("\n", "").replace("\\", "\\\\")
```

Backslashes are escaped **after** quotes, so the backslash just added for a
quote is escaped again: `a"b` becomes `a\\"b`. The `tib` session hit the
identical bug in its own collector and checked what VictoriaMetrics does with
the result — the malformed line is **dropped silently**, with the import
endpoint still returning HTTP 204. So any label value containing a quote
disappears with no error anywhere.

Fix is to escape backslashes first:

```python
return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "")
```

`tib` has already fixed and round-trip verified its copy.

Measured against VictoriaMetrics v1.151.0 with four outpost names: the old order
sent 4 lines, got HTTP 204, and stored **2** — both quote-containing values were
gone. The fixed order stores all 4 and round-trips `a"b\c` intact.

The other three were checked and are already correct — they escape the
backslash first:

| repo | location | order |
|---|---|---|
| `vib` | `scanner/scanner.py:190` | backslash first — OK |
| `pib` | `monitor/monitor.py:190` | backslash first — OK |
| `cib` | `checker/checker.py:140` | backslash first — OK |
| `iib` | `monitor/monitor.py:122` | **quotes first — bug** |

So `iib` is the only live instance in the umbrella, and it is the one repo with
no standalone checkout outside the submodule tree.

---

## 3. `make setup` silently generates no Authentik secrets on macOS — `iib` — **fix open in iib#2**

`iib/Makefile:22-24` uses GNU `sed -i`:

```make
sed -i "s|AUTHENTIK_SECRET_KEY=GENERATE_ME|...|" .env
```

BSD sed reads the next argument as the in-place suffix, so on macOS this fails
with `sed: 1: ".env": invalid command code .` — three times — and the recipe
still prints `Secrets generated.` because the failures are swallowed. Observed
directly from `make setup` at the XIB root:

```
Generating secrets...
sed: 1: ".env
": invalid command code .
sed: 1: ".env
": invalid command code .
sed: 1: ".env
": invalid command code .
Secrets generated.
```

`iib/.env` is left holding `AUTHENTIK_SECRET_KEY=GENERATE_ME`,
`AUTHENTIK_BOOTSTRAP_TOKEN=GENERATE_ME` and `POSTGRES_PASSWORD=GENERATE_ME`, so
Authentik cannot start and `make setup-sso` has no bootstrap token to use.
**`make up` does not work on macOS today.**

`scripts/init-env.sh` in this repo solves the same problem portably — write to a
temp file and copy it back, rather than relying on `sed -i` semantics.
`pib/Makefile`'s `ca-password` target is fine; it only appends.

The fix in iib#2 does the same, and additionally verifies the result so a future
failure cannot report success again. It also anchors both `GENERATE_ME` greps to
assignment lines: `.env.example` mentions the placeholder in a comment, so the
unanchored check matched even after every secret was filled in.
