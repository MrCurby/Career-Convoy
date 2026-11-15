#!/usr/bin/env python3
"""Generates the enlarged garage computer zones on West Coast USA.

Background: "Use computer" only appears when you stand on foot in the zone
"<name>Computer_area_<n>" (BeamNGGameplayArea). In the original the zones are about
2 x 1.4 m – you have to stand exactly in front of the computer.

This script reads BeamNG's original file (garage_interactions.original.json, from
content/levels/west_coast_usa.zip) and writes a version in which only the zones are larger.
Everything else (icons, IDs, rotation) stays exactly the same.

Every zone starts at the computer and reaches into the room (not through the wall to the
outside). The direction "into the room" follows from the side of the computer icon on which
the original zone lies.

'scale' are half edge lengths (that's how gameplay/markers/walkingMarker.lua calculates).

After a BeamNG update that changes this file:
  1. copy the new original file from west_coast_usa.zip to garage_interactions.original.json
     (levels/west_coast_usa/main/MissionGroup/career_garage/garage_interactions/items.level.json)
  2. python3 tools/zones/make_garage_zones.py
  3. tools/package.sh
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ORIGINAL = os.path.join(HERE, "garage_interactions.original.json")
OUTPUT = os.path.join(ROOT, "client", "levels", "west_coast_usa", "main", "MissionGroup",
                      "career_garage", "garage_interactions", "items.level.json")

# Size of the new zone (half edge lengths in meters):
WIDTH = 7.0    # across the computer: 14 m wide
DEPTH = 6.0    # from the computer into the room: 12 m deep ...
BEHIND = 1.0   # ... of which 1 m behind/next to the computer, so you can also stand to the side
MIN_HEIGHT = 2.0  # half height: reaches over steps and ramps


def axes(rot):
    """Local X and Y axis (columns of the rotation matrix), horizontal only."""
    x = (rot[0], rot[3])
    y = (rot[1], rot[4])
    return x, y


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1]


def enlarge(area, icon):
    pos, rot, scale = area["position"], area["rotationMatrix"], area["scale"]
    x_axis, y_axis = axes(rot)
    # from the computer marker to the original zone = direction into the room
    d = (pos[0] - icon["position"][0], pos[1] - icon["position"][1])
    px, py = dot(d, x_axis), dot(d, y_axis)
    if abs(py) >= abs(px):
        depth_axis, sign, depth_index, width_index = y_axis, (1 if py >= 0 else -1), 1, 0
    else:
        depth_axis, sign, depth_index, width_index = x_axis, (1 if px >= 0 else -1), 0, 1
    # the zone starts BEHIND meters behind the computer and reaches DEPTH*2 - BEHIND into the room
    offset = DEPTH - BEHIND
    cx = icon["position"][0] + depth_axis[0] * sign * offset
    cy = icon["position"][1] + depth_axis[1] * sign * offset
    new_scale = [0.0, 0.0, max(scale[2], MIN_HEIGHT)]
    new_scale[depth_index] = DEPTH
    new_scale[width_index] = WIDTH
    out = dict(area)
    out["position"] = [round(cx, 6), round(cy, 6), pos[2]]
    out["scale"] = [round(v, 6) for v in new_scale]
    return out


def main():
    with open(ORIGINAL, encoding="utf-8") as f:
        objects = [json.loads(line) for line in f if line.strip()]
    by_name = {o["name"]: o for o in objects}
    lines, changed = [], 0
    for obj in objects:
        name = obj["name"]
        if obj.get("class") == "BeamNGGameplayArea" and "Computer_area_" in name:
            icon = by_name.get(name.replace("_area_", "_icon_"))
            if icon is None:
                sys.exit(f"no icon for {name}")
            obj = enlarge(obj, icon)
            changed += 1
        lines.append(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{changed} computer zones enlarged -> {os.path.relpath(OUTPUT, ROOT)}")


if __name__ == "__main__":
    main()
