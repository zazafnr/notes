#!/bin/bash
# Baut simhelper (schneller Video-Strom, Drehen, Zwei-Finger-Gesten) gegen die Frameworks der
# installierten AXe-Version. Geht das schief, nutzt der Server die langsameren AXe-Befehle.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SIM_DIR=${SIM_DIR:-/tmp/sim}
FW="$(brew --prefix axe)/libexec/Frameworks"
PH="$SIM_DIR/idb-headers"
CACHE="$SIM_DIR/simhelper-cache"

# Schon gebaut (Cache von einer früheren Sitzung mit gleichem Xcode)? Dann nur prüfen und nehmen.
if [ -x "$CACHE/simhelper" ]; then
  "$CACHE/simhelper" > /dev/null 2>&1
  if [ $? -eq 2 ]; then
    cp "$CACHE/simhelper" "$SIM_DIR/simhelper"
    echo "simhelper aus dem Cache"
    exit 0
  fi
  echo "simhelper im Cache passt nicht mehr, baue neu"
fi

# Private Header (Modulkarten für CoreSimulator & Co.) aus genau dem idb-Stand, mit dem AXe gebaut ist.
VERSION=$(axe --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
IDB_REF=$(curl -fsSL "https://raw.githubusercontent.com/cameroncooke/AXe/v${VERSION}/scripts/build.sh" 2>/dev/null \
  | grep -oE 'DEFAULT_IDB_GIT_REF="[0-9a-f]{40}"' | grep -oE '[0-9a-f]{40}')
IDB_REF=${IDB_REF:-604c51013438f0c3603b720a05a44b7c5b8f286d}
echo "AXe ${VERSION:-?}, idb ${IDB_REF:0:10}"

rm -rf "$PH" && mkdir -p "$PH" && cd "$PH"
git init -q && git remote add origin https://github.com/cameroncooke/idb.git
git fetch -q --depth 1 origin "$IDB_REF" && git checkout -q FETCH_HEAD -- PrivateHeaders || { echo "Header nicht geladen"; exit 1; }

# Die Schnittstellen nennen Typen voll qualifiziert (»FBSimulatorControl.FBSimulator…«). Weil Modul und
# Klasse »FBSimulatorControl« gleich heißen, versteht der Compiler das nicht. Deshalb eine Kopie der
# Frameworks mit Schnittstellen ohne Modul-Präfix (auch »IOSurface.IOSurface« → »IOSurface«); die fertigen Binärmodule passen nur zur Swift-Version
# von AXe und werden entfernt, damit der Compiler die Schnittstellen nimmt.
FWC="$SIM_DIR/fw"
rm -rf "$FWC" && cp -R "$FW" "$FWC"
find "$FWC" -path '*.swiftmodule/*.swiftmodule' -delete
for f in $(find "$FWC" -name '*.swiftinterface'); do
  perl -pi -e 'unless (/^\s*(\@_exported\s+)?(\@preconcurrency\s+)?import /) { s/(?<![\w.])(FBSimulatorControl|FBControlCore|FBDeviceControl|XCTestBootstrap)\.(?=[A-Z_])//g; s/(?<![\w.])(\w+)\.\1\b/$1/g; }' "$f"
done

INC=()
for d in "" AccessibilityPlatformTranslation AXRuntime CoreSimDeviceIO CoreSimulator CoreSimulatorUtilities SimulatorKit; do
  INC+=("-I$PH/PrivateHeaders/$d")
done

xcrun swiftc -O -parse-as-library \
  -F "$FWC" "${INC[@]}" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -undefined -Xlinker dynamic_lookup \
  "$HERE/simhelper.swift" -o "$SIM_DIR/simhelper" 2>&1 | grep -vE "warning: -undefined dynamic_lookup" | tail -40
if [ ! -x "$SIM_DIR/simhelper" ]; then
  echo "simhelper ließ sich nicht bauen"
  exit 1
fi
codesign --force --sign - "$SIM_DIR/simhelper" 2>/dev/null || true
mkdir -p "$CACHE" && cp "$SIM_DIR/simhelper" "$CACHE/simhelper"
echo "simhelper gebaut"
