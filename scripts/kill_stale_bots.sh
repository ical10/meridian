#!/bin/bash
# Kill stale/duplicate Meridian bot instances, keeping only the newest one.
# Duplicate `index.js` processes cause double-deploys and double-management — only one may run.
# Usage:
#   ./scripts/kill_stale_bots.sh           # keep newest canonical bot, kill the rest
#   ./scripts/kill_stale_bots.sh --all      # kill ALL bot instances (full stop)
#   ./scripts/kill_stale_bots.sh --dry-run  # show what would be killed, change nothing

cd /root/meridian/meridian

DRY_RUN=0
KILL_ALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --all)     KILL_ALL=1 ;;
  esac
done

# Collect all bot-like PIDs. Includes canonical `node .../index.js` AND stray
# `node -e import('./index.js')` module-load tests that can linger from dev sessions
# and silently run cron loops.
mapfile -t ALL_PIDS < <(pgrep -f "index\.js" | while read -r pid; do
  # only real node binaries — never bash wrappers whose cmdline merely mentions index.js
  exe=$(basename "$(readlink "/proc/$pid/exe" 2>/dev/null)" 2>/dev/null)
  [ "$exe" = "node" ] || continue
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  case "$cmd" in
    *openclaw*) continue ;;                                  # unrelated gateway
    *"node "*"index.js"*) echo "$pid" ;;                     # canonical bot
    *"--input-type=module"*"index.js"*) echo "$pid" ;;       # stray module-load test
    *"-e "*"index.js"*) echo "$pid" ;;
  esac
done)

if [ "${#ALL_PIDS[@]}" -eq 0 ]; then
  echo "No bot processes found — nothing to do."
  exit 0
fi

# Sort PIDs by process start time (oldest first); newest is the one to keep.
mapfile -t SORTED < <(for pid in "${ALL_PIDS[@]}"; do
  start=$(stat -c %Y "/proc/$pid" 2>/dev/null || echo 0)
  echo "$start $pid"
done | sort -n | awk '{print $2}')

if [ "$KILL_ALL" -eq 1 ]; then
  KILL_LIST=("${SORTED[@]}")
  KEEP=""
else
  KEEP="${SORTED[-1]}"                                       # newest = keep
  KILL_LIST=("${SORTED[@]:0:${#SORTED[@]}-1}")               # everything else
fi

if [ -n "$KEEP" ]; then echo "Keeping newest bot: PID $KEEP"; fi

if [ "${#KILL_LIST[@]}" -eq 0 ]; then
  echo "No stale duplicates — only one instance running."
  exit 0
fi

for pid in "${KILL_LIST[@]}"; do
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-70)
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would kill PID $pid  ($cmd)"
  else
    if kill -9 "$pid" 2>/dev/null; then
      echo "killed PID $pid  ($cmd)"
    else
      echo "PID $pid already gone"
    fi
  fi
done
