#!/usr/bin/env python3
"""Fail if any service publishes a port without an explicit bind address.

Compose defaults an omitted host IP to 0.0.0.0, so a sub-project that forgets
the "${BIND_ADDR:-127.0.0.1}:" prefix silently exposes itself to the LAN while
the rest of the stack stays on loopback. That is invisible in the per-project
compose file and only shows up in the merged umbrella model, which is why this
check lives here.

Usage: check-port-bindings.py <docker compose config --format json output>
"""
import json
import pathlib
import sys

# Set BIND_ADDR=0.0.0.0 to expose the stack on purpose; this check only demands
# that the choice is explicit rather than defaulted.
ALLOWED_EMPTY: set[str] = set()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1])
        return 2

    model = json.loads(pathlib.Path(argv[1]).read_text())
    services = model.get("services") or {}
    if not services:
        print("FAIL compose model contains no services")
        return 1

    failures = []
    published = 0
    for name, service in sorted(services.items()):
        for port in service.get("ports") or []:
            published += 1
            host_ip = port.get("host_ip") or ""
            target = f"{port.get('published')}->{port.get('target')}"
            if not host_ip and name not in ALLOWED_EMPTY:
                failures.append(
                    f"{name}: {target} has no host IP, so Compose binds 0.0.0.0; "
                    f'prefix the mapping with "${{BIND_ADDR:-127.0.0.1}}:"'
                )
            elif host_ip:
                print(f"OK   {name}: {host_ip}:{target}")

    print(f"\n{published} published ports across {len(services)} services")
    for failure in failures:
        print(f"FAIL {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
