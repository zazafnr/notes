#!/bin/bash
# Wartet, bis die Simulatoren fertig hochgefahren sind, und stellt sie ein.
set -euo pipefail
SIM_DIR=${SIM_DIR:-/tmp/sim}
APPEARANCE=${APPEARANCE:-light}
LANGUAGE=${LANGUAGE:-de-DE}
LOCALE=${LOCALE:-de_DE}

UDIDS=$(python3 -c "import json;print(' '.join(d['udid'] for d in json.load(open('$SIM_DIR/devices.json'))))")
for udid in $UDIDS; do
  xcrun simctl boot "$udid" 2>/dev/null || true   # schon gestartet ist auch gut
done
for udid in $UDIDS; do
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl ui "$udid" appearance "$APPEARANCE" || true
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$LANGUAGE" || true
  xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$LOCALE" || true
done

# Simulator.app wird nur zum Drehen gebraucht (Menü »Device → Orientation«).
open -a Simulator || echo "Simulator.app nicht gefunden – Drehen ist in dieser Sitzung nicht möglich"
echo "Simulatoren bereit"
