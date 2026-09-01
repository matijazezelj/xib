#!/usr/bin/env python3
"""Check provisioned dashboards against the provisioned datasources.

Grafana silently tolerates both faults below: a panel whose targets name a
datasource that is not provisioned renders empty, and a panel whose targets span
several datasources without declaring "-- Mixed --" sends every query to the
panel datasource instead. Both look like "no data" rather than an error.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DASHBOARDS = ROOT / "grafana" / "dashboards"
DATASOURCES = ROOT / "grafana" / "provisioning" / "datasources"

MIXED = "-- Mixed --"
# Datasources Grafana provides itself, which are never in the provisioning file.
BUILTIN = {MIXED, "-- Grafana --", "-- Dashboard --", "grafana"}


def provisioned_uids() -> set[str]:
    uids = set()
    for path in sorted(DATASOURCES.glob("*.y*ml")):
        uids |= set(re.findall(r"^\s*uid:\s*(\S+)\s*$", path.read_text(), re.M))
    return uids


def panel_errors(panel: dict, known: set[str]) -> list[str]:
    errors = []
    title = panel.get("title") or f"id={panel.get('id')}"
    panel_uid = (panel.get("datasource") or {}).get("uid")

    target_uids = set()
    for target in panel.get("targets") or []:
        uid = (target.get("datasource") or {}).get("uid")
        if uid:
            target_uids.add(uid)

    for uid in target_uids | ({panel_uid} if panel_uid else set()):
        if uid not in known and uid not in BUILTIN:
            errors.append(f"{title!r}: datasource uid {uid!r} is not provisioned")

    if len(target_uids) > 1 and panel_uid != MIXED:
        errors.append(
            f"{title!r}: targets span {sorted(target_uids)} but the panel "
            f"datasource is {panel_uid!r}; multi-datasource panels need {MIXED!r} "
            f"or every query goes to one datasource"
        )
    # A single target pointing somewhere other than its panel is the same bug.
    if len(target_uids) == 1 and panel_uid not in (None, MIXED):
        (only,) = target_uids
        if only != panel_uid:
            errors.append(
                f"{title!r}: target uses {only!r} but the panel datasource is "
                f"{panel_uid!r}; the panel datasource wins"
            )
    return errors


def main() -> int:
    known = provisioned_uids()
    if not known:
        print(f"FAIL no datasource uids found under {DATASOURCES}")
        return 1
    print(f"provisioned datasources: {', '.join(sorted(known))}")

    errors = []
    files = sorted(DASHBOARDS.glob("*.json"))
    if not files:
        print(f"FAIL no dashboards found under {DASHBOARDS}")
        return 1

    for path in files:
        try:
            dashboard = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            errors.append(f"{path.name}: invalid JSON: {e}")
            continue
        panels = dashboard.get("panels") or []
        for panel in panels:
            errors += [f"{path.name}: {e}" for e in panel_errors(panel, known)]
        print(f"OK   {path.name}: {len(panels)} panels, uid={dashboard.get('uid')!r}")

    for error in errors:
        print(f"FAIL {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
