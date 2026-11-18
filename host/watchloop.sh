#!/bin/bash
# Poll Teams badge every 20s for up to 15 min; exit 1 on YELLOW/RED.
for i in $(seq 1 45); do
  r=$(python3 "$(dirname "$0")/teamswatch.py" "${1:?usage: watchloop.sh <teams-window-id>}" 2>&1 | head -1)
  echo "$(date +%H:%M:%S) $r | jiggles: $(grep -c jiggled "${JIGGLE_LOG:-jiggle.log}" 2>/dev/null)"
  case "$r" in YELLOW*|RED*) echo "ALERT: status changed to $r"; exit 1;; esac
  sleep 20
done
echo "15 min elapsed, status stayed green"
