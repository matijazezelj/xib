#!/usr/bin/env python3
"""Fail if the merged compose model has a mutable image tag or a Docker socket mount.

Two things this stack's own audit of a real lab turned up, and which CI should
stop from coming back:

  * Mutable tags. `:latest` (or no tag) means the same file deploys different
    software next month. One upstream tag used here has since vanished, which
    broke a fresh install outright. Images built locally (they have a `build:`
    section) are exempt: they are rebuilt from this repo.
  * Docker socket mounts. A scanner that only needs to *list images* does not
    need root on the host. Use a read-only socket proxy (see
    docs/read-only-docker-proxy.md) and DOCKER_HOSTS instead.

Exceptions are explicit and documented below, not silent.

Usage: check-image-policy.py [--allow-socket] <docker compose config --format json output>

--allow-socket  skip the socket check (tags are still enforced). The plain `make up`
                path still lets vib-scanner and cib-checker mount the socket, which is
                a deliberate, documented trade-off; the `make up-safe` path must have none.
"""
import json
import pathlib
import sys

# service name -> why it may keep a socket mount. Empty on purpose.
SOCKET_ALLOWED: dict[str, str] = {
    # The read-only proxy is the one thing that touches the socket, so nothing else has to.
    "docker-proxy": "tecnativa/docker-socket-proxy, GET-only, on an internal network",
}

# Mounts of the socket that exist upstream and that the umbrella removes by
# default are NOT listed here: the point is that nothing should need them.
SOCKET_PATHS = ("/var/run/docker.sock", "/run/docker.sock")

MUTABLE_TAGS = {"latest", "stable", "edge", "main", "master", "release", "nightly"}


def tag_of(image: str) -> str:
    ref = image.split("@", 1)[0]  # a digest pins it regardless of tag
    if "@" in image:
        return "pinned-by-digest"
    last = ref.rsplit("/", 1)[-1]
    return last.split(":", 1)[1] if ":" in last else ""


def main(argv: list[str]) -> int:
    allow_socket = "--allow-socket" in argv
    argv = [a for a in argv if a != "--allow-socket"]
    if len(argv) != 2:
        print((__doc__ or "").strip().splitlines()[-1])
        return 2
    model = json.loads(pathlib.Path(argv[1]).read_text())
    services = model.get("services") or {}
    if not services:
        print("FAIL compose model contains no services")
        return 1

    failures = []
    checked = 0
    for name, svc in sorted(services.items()):
        image = svc.get("image") or ""
        if image and not svc.get("build"):
            checked += 1
            tag = tag_of(image)
            if tag == "" or tag in MUTABLE_TAGS:
                failures.append(f"{name}: image {image!r} has a mutable tag ({tag or 'none'}); pin a version or a digest")
        for vol in svc.get("volumes") or []:
            src = vol.get("source", "") if isinstance(vol, dict) else str(vol).split(":", 1)[0]
            if not allow_socket and src in SOCKET_PATHS and name not in SOCKET_ALLOWED:
                failures.append(f"{name}: mounts the Docker socket ({src}); use a read-only socket proxy + DOCKER_HOSTS")

    if failures:
        print("FAIL image/socket policy:")
        for f in failures:
            print("  -", f)
        return 1
    print(f"OK {checked} pre-built images are pinned and no service mounts the Docker socket")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
