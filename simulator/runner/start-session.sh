#!/bin/bash
# Startet Steuer-Server und Cloudflare-Tunnel und meldet die Adresse an die PC-App.
# Umgebung: SIM_DIR, SESSION, AUTH_HASH, MINUTES, APP_DIR, APP_REF, DEVICES, GH_TOKEN
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SIM_DIR=${SIM_DIR:-/tmp/sim}
MINUTES=${MINUTES:-60}

APP_JSON=null
BUILD_STATE=none
if [ -f "$SIM_DIR/app.json" ]; then
  APP_JSON=$(cat "$SIM_DIR/app.json")
  BUILD_STATE=ok
elif [ -f "$SIM_DIR/build.log" ]; then
  BUILD_STATE=failed
fi

python3 - <<PY
import json, os, time
cfg = {
  "session": os.environ["SESSION"],
  "authHash": os.environ["AUTH_HASH"].strip().lower(),
  "devices": json.load(open("$SIM_DIR/devices.json")),
  "app": json.loads('''$APP_JSON'''),
  "buildState": "$BUILD_STATE",
  "simDir": "$SIM_DIR",
  "appDir": os.environ.get("APP_DIR") or None,
  "ref": os.environ.get("APP_REF") or None,
  "devicesWanted": os.environ.get("DEVICES", "beide"),
  "buildScript": "$HERE/build-app.sh",
  "xcode": os.popen("xcodebuild -version | head -1").read().strip(),
  "deadline": int((time.time() + int("$MINUTES") * 60) * 1000),
}
json.dump(cfg, open("$SIM_DIR/session.json", "w"), indent=2)
PY

cd "$HERE/../server"
npm ci --no-audit --no-fund --omit=dev
if [ -x "$SIM_DIR/simhelper" ]; then export SIMHELPER="$SIM_DIR/simhelper"; fi
SIM_CONFIG="$SIM_DIR/session.json" nohup node server.js > "$SIM_DIR/server.log" 2>&1 &
echo $! > "$SIM_DIR/server.pid"

for i in $(seq 1 50); do
  curl -fsS http://127.0.0.1:8787/healthz > /dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS http://127.0.0.1:8787/healthz > /dev/null || { cat "$SIM_DIR/server.log"; exit 1; }

nohup cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8787 > "$SIM_DIR/tunnel.log" 2>&1 &
echo $! > "$SIM_DIR/tunnel.pid"

URL=""
for i in $(seq 1 120); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$SIM_DIR/tunnel.log" | head -1 || true)
  [ -n "$URL" ] && break
  sleep 0.5
done
if [ -z "$URL" ]; then
  cat "$SIM_DIR/tunnel.log"
  "$HERE/status.sh" error "Tunnel ließ sich nicht öffnen"
  exit 1
fi

# Erst nachschlagen, wenn der Tunnel angemeldet ist: eine zu frühe DNS-Anfrage merkt sich
# »gibt es nicht« für Minuten (auf dem Mac und beim PC).
for i in $(seq 1 60); do
  grep -q "Registered tunnel connection" "$SIM_DIR/tunnel.log" && break
  sleep 0.5
done
HOST=${URL#https://}
for i in $(seq 1 30); do
  IP=$(dig +short @1.1.1.1 "$HOST" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)
  if [ -n "$IP" ] && curl -fsS --max-time 5 --resolve "$HOST:443:$IP" "$URL/healthz" > /dev/null 2>&1; then
    echo "Tunnel erreichbar: $URL"
    break
  fi
  sleep 1
done
echo "$URL" > "$SIM_DIR/url"
"$HERE/status.sh" success "bereit" "$URL"
