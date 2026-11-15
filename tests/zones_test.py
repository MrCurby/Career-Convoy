#!/usr/bin/env python3
"""Checks the generated garage zones against the BeamNG original.
Run: python3 tests/zones_test.py"""
import importlib.util, json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("zones", os.path.join(ROOT, "tools/zones/make_garage_zones.py"))
zones = importlib.util.module_from_spec(spec); spec.loader.exec_module(zones)

ok = fail = 0
def check(cond, msg):
    global ok, fail
    if cond: ok += 1
    else: fail += 1; print("FAILED:", msg)

orig = [json.loads(l) for l in open(zones.ORIGINAL, encoding="utf-8") if l.strip()]
gen = [json.loads(l) for l in open(zones.OUTPUT, encoding="utf-8") if l.strip()]
check(len(orig) == len(gen), "same number of objects as in the original")
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
                check(o[key] == g[key], f"{o['name']}: {key} unchanged")
        check(g["position"][2] == o["position"][2], f"{o['name']}: height unchanged")
        icon = by_name[o["name"].replace("_area_", "_icon_")]
        check(inside(icon["position"], g), f"{o['name']}: computer lies in the new zone")
        check(inside(o["position"], g), f"{o['name']}: old zone lies inside the new one")
        check(g["scale"][0] * g["scale"][1] > 20 * o["scale"][0] * o["scale"][1], f"{o['name']}: clearly larger")
    else:
        check(o == g, f"{o['name']}: unchanged")

# the file must match the script (regenerate it after changing the script!)
before = open(zones.OUTPUT, encoding="utf-8").read()
zones.main()
check(open(zones.OUTPUT, encoding="utf-8").read() == before, "generated file is up to date")
print(f"Zones: {ok} ok, {fail} failed")
sys.exit(1 if fail else 0)
