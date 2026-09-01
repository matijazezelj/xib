# Findings that belong in the sub-project repos

Found while auditing the XIB umbrella on 2026-09-01. Each of these lives in a
submodule, so they are recorded here rather than fixed in `xib`. All three were
reproduced, not inferred.

---

## 1. TIB publishes two ports on 0.0.0.0 — `tib` — **fixed upstream, not yet committed**

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

The `tib` session confirmed this independently — `docker ps` showed
`0.0.0.0:8430->8428`, and a curl from its LAN address returned HTTP 200 — and
has the fix staged locally along with a `BIND_ADDR` block in `.env.example`.
Nothing is committed yet; `tib` master is still on `fa64459`, which is what this
repo pins, so **do not bump the submodule pointer until that commit lands.**

XIB now guards against a regression: `scripts/check-port-bindings.py` runs in CI
and fails on any published port without an explicit host IP. It will stay red
until the `tib` fix is committed and the pointer is bumped — that is intended,
the exposure is real.

---

## 2. `_safe_label` escapes in the wrong order — `iib`

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

`tib` has already fixed and round-trip verified its copy. `iib` still has it.

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

## 3. `make setup` silently generates no Authentik secrets on macOS — `iib`

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
temp file and `mv` it over, rather than relying on `sed -i` semantics.
`pib/Makefile`'s `ca-password` target is fine; it only appends.
