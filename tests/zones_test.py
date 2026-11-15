#!/usr/bin/env python3
"""Prüft die erzeugten Werkstatt-Zonen gegen das BeamNG-Original.
Ausführen: python3 tests/zones_test.py"""
import importlib.util, json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("zones", os.path.join(ROOT, "tools/zones/make_garage_zones.py"))
zones = importlib.util.module_from_spec(spec); spec.loader.exec_module(zones)

ok = fail = 0
def check(cond, msg):
    global ok, fail
    if cond: ok += 1
    else: fail += 1; print("FEHLER:", msg)

orig = [json.loads(l) for l in open(zones.ORIGINAL, encoding="utf-8") if l.strip()]
gen = [json.loads(l) for l in open(zones.OUTPUT, encoding="utf-8") if l.strip()]
check(len(orig) == len(gen), "gleich viele Objekte wie im Original")
by_name = {o["name"]: o for o in orig}

def inside(point, area, margin=0.0):
    x_axis, y_axis = zones.axes(area["rotationMatrix"])
    d = (point[0] - area["position"][0], point[1] - area["position"][1])
    return (abs(zones.dot(d, x_axis)) <= area["scale"][0] + margin and
            abs(zones.dot(d, y_axis)) <= area["scale"][1] + margin)

for o, g in zip(orig, gen):
    if "Computer_area_" in o["name"]:
        for key in o:
            if key not in ("position", "scale"):
                check(o[key] == g[key], f"{o['name']}: {key} unverändert")
        check(g["position"][2] == o["position"][2], f"{o['name']}: Höhe unverändert")
        icon = by_name[o["name"].replace("_area_", "_icon_")]
        check(inside(icon["position"], g), f"{o['name']}: Computer liegt in der neuen Zone")
        check(inside(o["position"], g), f"{o['name']}: alte Zone liegt in der neuen")
        check(g["scale"][0] * g["scale"][1] > 20 * o["scale"][0] * o["scale"][1], f"{o['name']}: deutlich größer")
    else:
        check(o == g, f"{o['name']}: unverändert")

# Datei muss zum Skript passen (nach Änderungen am Skript neu erzeugen!)
before = open(zones.OUTPUT, encoding="utf-8").read()
zones.main()
check(open(zones.OUTPUT, encoding="utf-8").read() == before, "erzeugte Datei ist aktuell")
print(f"Zonen: {ok} ok, {fail} Fehler")
sys.exit(1 if fail else 0)
