#!/usr/bin/env python3
"""Erzeugt die vergrößerten Computer-Zonen der Werkstätten auf West Coast USA.

Hintergrund: "Computer benutzen" erscheint nur, wenn man zu Fuß in der Zone
"<name>Computer_area_<n>" steht (BeamNGGameplayArea). Im Original sind die Zonen etwa
2 x 1,4 m groß – man muss genau vor dem Computer stehen.

Dieses Skript liest die Original-Datei von BeamNG (garage_interactions.original.json, aus
content/levels/west_coast_usa.zip) und schreibt eine Version, in der nur die Zonen größer
sind. Alles andere (Symbole, IDs, Drehung) bleibt exakt gleich.

Jede Zone beginnt am Computer und reicht in den Raum hinein (nicht durch die Wand nach
draußen). Die Richtung "in den Raum" ergibt sich daraus, auf welcher Seite des Computer-
Symbols die Original-Zone liegt.

'scale' sind halbe Kantenlängen (so rechnet gameplay/markers/walkingMarker.lua).

Nach einem BeamNG-Update, das diese Datei ändert:
  1. neue Original-Datei aus west_coast_usa.zip nach garage_interactions.original.json kopieren
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

# Größe der neuen Zone (halbe Kantenlängen in Metern):
WIDTH = 7.0    # quer zum Computer: 14 m breit
DEPTH = 6.0    # vom Computer in den Raum: 12 m tief ...
BEHIND = 1.0   # ... davon 1 m hinter/neben dem Computer, damit man auch seitlich steht
MIN_HEIGHT = 2.0  # halbe Höhe: reicht über Stufen und Rampen


def axes(rot):
    """Lokale X- und Y-Achse (Spalten der Rotationsmatrix), nur waagerecht."""
    x = (rot[0], rot[3])
    y = (rot[1], rot[4])
    return x, y


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1]


def enlarge(area, icon):
    pos, rot, scale = area["position"], area["rotationMatrix"], area["scale"]
    x_axis, y_axis = axes(rot)
    # Von der Computer-Markierung zur Original-Zone = Richtung in den Raum
    d = (pos[0] - icon["position"][0], pos[1] - icon["position"][1])
    px, py = dot(d, x_axis), dot(d, y_axis)
    if abs(py) >= abs(px):
        depth_axis, sign, depth_index, width_index = y_axis, (1 if py >= 0 else -1), 1, 0
    else:
        depth_axis, sign, depth_index, width_index = x_axis, (1 if px >= 0 else -1), 0, 1
    # Zone beginnt BEHIND Meter hinter dem Computer und reicht DEPTH*2 - BEHIND in den Raum
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
                sys.exit(f"kein Symbol zu {name}")
            obj = enlarge(obj, icon)
            changed += 1
        lines.append(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{changed} Computer-Zonen vergrößert -> {os.path.relpath(OUTPUT, ROOT)}")


if __name__ == "__main__":
    main()
