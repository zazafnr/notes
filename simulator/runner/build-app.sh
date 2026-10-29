#!/bin/bash
# Baut die App aus $APP_DIR für den iOS-Simulator und schreibt $SIM_DIR/app.json (Pfad, Bundle-ID).
# Erkennt Swift-Playgrounds-Pakete (.swiftpm), Workspaces und Xcode-Projekte.
#
# Umgebung: APP_DIR, SIM_DIR, APP_REF (optional: vorher diesen Branch holen),
#           APP_PATH (Unterordner oder auto), DEVICES (beide|iphone|ipad)
set -uo pipefail
SIM_DIR=${SIM_DIR:-/tmp/sim}
APP_DIR=${APP_DIR:?APP_DIR fehlt}
APP_PATH=${APP_PATH:-auto}
DEVICES=${DEVICES:-beide}
LOG="$SIM_DIR/build.log"
OUT="$SIM_DIR/build"
mkdir -p "$SIM_DIR"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

cd "$APP_DIR"
if [ -n "${APP_REF:-}" ] && [ -d .git ]; then
  echo "==> Hole neuesten Stand von $APP_REF"
  git fetch --depth 1 origin "$APP_REF" && git checkout --force FETCH_HEAD && git clean -fdq
  git log -1 --format='==> Commit %h: %s'
fi

if [ "$APP_PATH" = "auto" ]; then
  PROJECT=$(find . -maxdepth 3 -name '*.swiftpm' -type d -not -path '*/.*' | sort | head -1)
  [ -z "$PROJECT" ] && PROJECT=$(find . -maxdepth 3 -name '*.xcworkspace' -not -path '*.xcodeproj/*' -not -path '*/.*' | sort | head -1)
  [ -z "$PROJECT" ] && PROJECT=$(find . -maxdepth 3 -name '*.xcodeproj' -not -path '*/.*' | sort | head -1)
else
  PROJECT="$APP_PATH"
fi
if [ -z "$PROJECT" ]; then
  echo "error: Kein .swiftpm, .xcworkspace oder .xcodeproj gefunden"
  exit 1
fi
echo "==> Projekt: $PROJECT"

ARGS=()
case "$PROJECT" in
  *.swiftpm)
    cd "$PROJECT"
    # iPad-only-Apps zum Testen auch aufs iPhone lassen (nur in dieser Kopie auf dem Cloud-Mac).
    if [ "$DEVICES" != "ipad" ] && grep -q 'supportedDeviceFamilies' Package.swift && ! grep -q '\.phone' Package.swift; then
      echo "==> App ist nur fürs iPad eingestellt – für den Test zusätzlich iPhone erlaubt"
      perl -0pi -e 's/supportedDeviceFamilies:\s*\[\s*\.pad\s*\]/supportedDeviceFamilies: [.pad, .phone]/' Package.swift
    fi
    SCHEME=$(xcodebuild -list -json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); w=d.get("workspace") or d.get("project") or {}; print((w.get("schemes") or [""])[0])')
    ;;
  *.xcworkspace)
    ARGS=(-workspace "$PROJECT")
    SCHEME=$(xcodebuild -list -json -workspace "$PROJECT" 2>/dev/null | python3 -c 'import json,sys; print((json.load(sys.stdin)["workspace"].get("schemes") or [""])[0])')
    ;;
  *.xcodeproj)
    ARGS=(-project "$PROJECT")
    SCHEME=$(xcodebuild -list -json -project "$PROJECT" 2>/dev/null | python3 -c 'import json,sys; print((json.load(sys.stdin)["project"].get("schemes") or [""])[0])')
    ;;
esac
SCHEME=${APP_SCHEME:-$SCHEME}
if [ -z "$SCHEME" ]; then
  echo "error: Kein Scheme gefunden"
  exit 1
fi
echo "==> Scheme: $SCHEME"

echo "==> BUILD startet (xcodebuild, iOS-Simulator)"
xcodebuild build ${ARGS[@]+"${ARGS[@]}"} \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$OUT" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$SIM_DIR/xcodebuild.log" | grep -E "error:|warning: .*deprecated|BUILD (SUCCEEDED|FAILED)|^\*\*" || true

if ! grep -q "BUILD SUCCEEDED" "$SIM_DIR/xcodebuild.log"; then
  echo "==> BUILD FAILED – Fehler:"
  grep -E "error:" "$SIM_DIR/xcodebuild.log" | sort -u | head -60
  grep -q "error:" "$SIM_DIR/xcodebuild.log" || tail -40 "$SIM_DIR/xcodebuild.log"
  exit 1
fi

APP=$(find "$OUT/Build/Products" -maxdepth 2 -path '*-iphonesimulator/*.app' -type d | head -1)
if [ -z "$APP" ]; then
  echo "error: Gebaute .app nicht gefunden"
  exit 1
fi
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP/Info.plist")
python3 -c 'import json,sys; json.dump({"path":sys.argv[1],"bundle":sys.argv[2],"name":sys.argv[3]}, open(sys.argv[4],"w"))' "$APP" "$BUNDLE" "$NAME" "$SIM_DIR/app.json"
echo "==> BUILD fertig: $NAME ($BUNDLE)"
