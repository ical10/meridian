#!/bin/bash
# Tight monitor for dump_spot DRY-RUN behavior.
# Runs every 30 min, captures screening decisions and LLM narratives since last run.
# Self-removes from crontab after 24h. Output: checkpoints/dump_spot_monitor.log

set -e
cd /root/meridian/meridian
mkdir -p checkpoints

STATE_FILE="checkpoints/dump_spot_monitor.state"
OUT_FILE="checkpoints/dump_spot_monitor.log"

# Initialize first-run timestamp
if [ ! -f "$STATE_FILE" ]; then
  date -u +%s > "$STATE_FILE"
fi
STARTED_AT=$(cat "$STATE_FILE")
NOW=$(date -u +%s)
ELAPSED_H=$(( (NOW - STARTED_AT) / 3600 ))

# Self-remove from crontab after 24h
if [ "$ELAPSED_H" -ge 24 ]; then
  echo "" >> "$OUT_FILE"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Monitor window ended (24h elapsed). Self-removing from crontab." >> "$OUT_FILE"
  crontab -l 2>/dev/null | grep -v 'monitor_dump_spot' | crontab -
  rm -f "$STATE_FILE"
  exit 0
fi

LOG="logs/agent-$(date -u +%Y-%m-%d).log"
[ -f "$LOG" ] || { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] no log file $LOG yet" >> "$OUT_FILE"; exit 0; }

CUTOFF="$(date -u -d '35 minutes ago' +%Y-%m-%dT%H:%M)"

{
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] dump_spot monitor — last 35min (elapsed ${ELAPSED_H}h / 24h budget)"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""

  echo "--- CYCLE EVENTS ---"
  awk -v c="[$CUTOFF" '$0 >= c' "$LOG" \
    | grep -E "Starting screening|🚀 DEPLOYED|⛔ NO DEPLOY|Final answer reached|CRON_ERROR|Screening skipped" \
    | tail -15 \
    || echo "  (none)"

  echo ""
  echo "--- DRY-RUN OUTCOMES (no on-chain action) ---"
  awk -v c="[$CUTOFF" '$0 >= c' "$LOG" \
    | grep -iE "dry_run|would_deploy|dry run mode|DRY RUN —" \
    | tail -10 \
    || echo "  (none)"

  echo ""
  echo "--- LLM NARRATIVES (last few decisions) ---"
  awk -v c="[$CUTOFF" '$0 >= c' "$LOG" \
    | grep -B 1 -A 6 -E "WHY THIS WON|WHY SKIPPED" \
    | tail -40 \
    || echo "  (none)"

  echo ""
  echo "--- ERRORS / WARNINGS ---"
  awk -v c="[$CUTOFF" '$0 >= c' "$LOG" \
    | grep -E "CRON_ERROR|ERROR|WALLET_ERROR|Agent loop error" \
    | grep -v HIVEMIND_WARN \
    | tail -10 \
    || echo "  (none)"

} >> "$OUT_FILE" 2>&1
