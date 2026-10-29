#!/bin/bash
# Meldet den Stand der Sitzung als Commit-Status, dort liest ihn die PC-App.
# Aufruf: status.sh <pending|success|failure|error> "<Text>" [URL]
STATE=$1
TEXT=$2
URL=${3:-${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}}
BODY=$(python3 -c 'import json,sys; print(json.dumps({"state":sys.argv[1],"description":sys.argv[2][:139],"context":sys.argv[3],"target_url":sys.argv[4]}))' \
  "$STATE" "$TEXT" "ios-sim/${SESSION}" "$URL")
curl -fsS -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}" \
  -d "$BODY" > /dev/null || echo "Status konnte nicht gemeldet werden"
echo "Status: $STATE – $TEXT"
