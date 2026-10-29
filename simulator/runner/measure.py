#!/usr/bin/env python3
"""Misst Pixel- und Punktgröße der laufenden Simulatoren und trägt sie in devices.json ein.

Pixel: Bildschirmfoto (simctl). Punkte: Rahmen der obersten Bedienungshilfen-Ebene (axe describe-ui).
"""
import json, os, re, subprocess, sys

sim_dir = os.environ.get("SIM_DIR", "/tmp/sim")
path = os.path.join(sim_dir, "devices.json")
devices = json.load(open(path))

def png_size(file):
    out = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", file], text=True)
    w = int(re.search(r"pixelWidth: (\d+)", out).group(1))
    h = int(re.search(r"pixelHeight: (\d+)", out).group(1))
    return w, h

def point_size(udid):
    try:
        tree = json.loads(subprocess.check_output(["axe", "describe-ui", "--udid", udid], text=True, timeout=60))
    except Exception as err:
        print(f"describe-ui: {err}", file=sys.stderr)
        return None
    roots = tree if isinstance(tree, list) else [tree]
    best = None
    for node in roots:
        f = node.get("frame") or {}
        if f.get("width") and f.get("height"):
            size = (f["width"], f["height"])
            if not best or size[0] * size[1] > best[0] * best[1]:
                best = size
    return best

for d in devices:
    shot = os.path.join(sim_dir, f"measure-{d['role']}.png")
    subprocess.run(["xcrun", "simctl", "io", d["udid"], "screenshot", "--type=png", shot], check=True, capture_output=True)
    w, h = png_size(shot)
    pw, ph = (min(w, h), max(w, h))  # immer Hochformat speichern
    if not d.get("pixelWidth") or not d.get("pixelHeight"):
        d["pixelWidth"], d["pixelHeight"] = pw, ph
    if not d.get("scale"):
        pts = point_size(d["udid"])
        if pts:
            d["scale"] = round(pw / min(pts))
        else:
            d["scale"] = 3 if d["role"] == "iphone" else 2
    print(f"{d['role']}: {d['pixelWidth']}×{d['pixelHeight']} px, @{d['scale']}x → {d['pixelWidth']/d['scale']:.0f}×{d['pixelHeight']/d['scale']:.0f} pt")

json.dump(devices, open(path, "w"), indent=2)
