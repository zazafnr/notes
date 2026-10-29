#!/bin/bash
# Legt frische Simulatoren an (neuestes iOS auf diesem Mac) und startet sie im Hintergrund.
# Schreibt $SIM_DIR/devices.json für den Steuer-Server.
#
# Umgebung: SIM_DIR, DEVICES (beide|iphone|ipad), IPHONE_MODEL, IPAD_MODEL (Name oder auto),
#           LANGUAGE (z. B. de-DE), LOCALE (z. B. de_DE)
set -euo pipefail
SIM_DIR=${SIM_DIR:-/tmp/sim}
mkdir -p "$SIM_DIR"

xcrun simctl list runtimes -j > "$SIM_DIR/runtimes.json"

python3 - "$SIM_DIR" <<'PY'
import json, os, plistlib, re, subprocess, sys

sim_dir = sys.argv[1]
want = os.environ.get("DEVICES", "beide")
roles = {"beide": ["iphone", "ipad"], "iphone": ["iphone"], "ipad": ["ipad"]}.get(want, ["iphone", "ipad"])
language = os.environ.get("LANGUAGE") or "de-DE"
locale = os.environ.get("LOCALE") or "de_DE"

runtimes = json.load(open(os.path.join(sim_dir, "runtimes.json")))["runtimes"]
ios = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable")]
if not ios:
    sys.exit("Kein iOS-Simulator auf diesem Mac installiert")
def version_key(r):
    return [int(x) for x in re.findall(r"\d+", r["version"])]
ios.sort(key=version_key)

def number(name):
    m = re.search(r"(\d+)", name)
    return int(m.group(1)) if m else 0

def pick(role, requested, types):
    family = "iPhone" if role == "iphone" else "iPad"
    candidates = [t for t in types if t.get("productFamily") == family]
    if requested and requested != "auto":
        for t in candidates:
            if t["name"] == requested:
                return t
        print(f"Modell »{requested}« gibt es hier nicht, nehme Standard", file=sys.stderr)
    if role == "iphone":
        pro = [t for t in candidates if re.fullmatch(r"iPhone \d+ Pro", t["name"])]
        pool = pro or candidates
        return max(pool, key=lambda t: number(t["name"]))
    pro13 = [t for t in candidates if t["name"].startswith("iPad Pro 13")]
    pro11 = [t for t in candidates if t["name"].startswith("iPad Pro 11")]
    pool = pro13 or pro11 or candidates
    return max(pool, key=lambda t: number(t["name"].split("(")[-1]))

# Bildschirmmaße aus dem Gerätetyp; ab Xcode 27 stehen sie nicht mehr sicher in profile.plist.
# Fehlen sie, misst measure.py sie nach dem Start am laufenden Gerät.
def screen_info(bundle_path):
    found = {}
    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in ("mainScreenWidth", "mainScreenHeight", "mainScreenScale") and isinstance(v, (int, float)):
                    found.setdefault(k, v)
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    resources = os.path.join(bundle_path, "Contents", "Resources")
    for name in ("profile.plist", "capabilities.plist"):
        try:
            walk(plistlib.load(open(os.path.join(resources, name), "rb")))
        except Exception:
            pass
    return found

# Neueste Runtime, die alle gewünschten Gerätearten kann (manche Punkt-Releases haben nur ein Gerät).
runtime = None
for r in reversed(ios):
    fams = {t.get("productFamily") for t in r.get("supportedDeviceTypes", [])}
    if all(("iPhone" if role == "iphone" else "iPad") in fams for role in roles):
        runtime = r
        break
runtime = runtime or ios[-1]
print(f"iOS-Version: {runtime['name']} ({runtime['buildversion']})")

devices = []
for role in roles:
    requested = os.environ.get("IPHONE_MODEL" if role == "iphone" else "IPAD_MODEL", "auto")
    t = pick(role, requested, runtime["supportedDeviceTypes"])
    name = "PC-iPhone" if role == "iphone" else "PC-iPad"
    udid = subprocess.check_output(["xcrun", "simctl", "create", name, t["identifier"], runtime["identifier"]], text=True).strip()
    screen = screen_info(t["bundlePath"])
    # Sprache und Region schon vor dem ersten Start setzen, damit auch der Home-Bildschirm deutsch ist.
    prefs_dir = os.path.expanduser(f"~/Library/Developer/CoreSimulator/Devices/{udid}/data/Library/Preferences")
    os.makedirs(prefs_dir, exist_ok=True)
    prefs_path = os.path.join(prefs_dir, ".GlobalPreferences.plist")
    prefs = {}
    if os.path.exists(prefs_path):
        try:
            prefs = plistlib.load(open(prefs_path, "rb"))
        except Exception:
            prefs = {}
    prefs.update({"AppleLanguages": [language], "AppleLocale": locale})
    plistlib.dump(prefs, open(prefs_path, "wb"))
    devices.append({
        "role": role,
        "udid": udid,
        "name": name,
        "model": t["name"],
        "runtime": runtime["identifier"],
        "runtimeName": runtime["name"],
        "scale": screen.get("mainScreenScale"),
        "pixelWidth": screen.get("mainScreenWidth"),
        "pixelHeight": screen.get("mainScreenHeight"),
    })
    print(f"{role}: {t['name']} → {udid} ({screen.get('mainScreenWidth')}×{screen.get('mainScreenHeight')} @{screen.get('mainScreenScale')}x)")

json.dump(devices, open(os.path.join(sim_dir, "devices.json"), "w"), indent=2)
PY

# Mit NO_BOOT=1 nur anlegen: dann startet wait-boot.sh sie später (z. B. erst nach dem App-Build,
# weil der erste Start viel Rechenzeit kostet und den Build sonst stark bremst).
if [ "${NO_BOOT:-0}" != "1" ]; then
  for udid in $(python3 -c "import json;print(' '.join(d['udid'] for d in json.load(open('$SIM_DIR/devices.json'))))"); do
    xcrun simctl boot "$udid"
  done
  echo "Simulatoren starten im Hintergrund"
fi
