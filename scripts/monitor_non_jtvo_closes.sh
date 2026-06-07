#!/bin/bash
# Capture next 4 non-JTVO position closes to compare against this morning's session.
# Self-removes from crontab after 4 closes captured OR 24h elapsed, whichever first.
# Output: checkpoints/non_jtvo_closes.log

set -e
cd /root/meridian/meridian
mkdir -p checkpoints

STATE_FILE="checkpoints/non_jtvo_closes.state"
OUT_FILE="checkpoints/non_jtvo_closes.log"
COUNT_FILE="checkpoints/non_jtvo_closes.count"

if [ ! -f "$STATE_FILE" ]; then
  date -u +%s > "$STATE_FILE"
  echo "0" > "$COUNT_FILE"
  {
    echo "═══════════════════════════════════════════════════════════════════"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Monitor started — capturing next 4 non-JTVO closes"
    echo "Baseline (today's JTVO): 6 deploys, ~5 small/losses + 1 win (+6.89%)"
    echo "Active config: TP=10, SL=-5, trailingTrigger=2.5, trailingDrop=1.5"
    echo "═══════════════════════════════════════════════════════════════════"
  } >> "$OUT_FILE"
fi

STARTED_AT=$(cat "$STATE_FILE")
NOW=$(date -u +%s)
ELAPSED_H=$(( (NOW - STARTED_AT) / 3600 ))
COUNT=$(cat "$COUNT_FILE")

# Stop after 4 captured or 24h elapsed
if [ "$COUNT" -ge 4 ] || [ "$ELAPSED_H" -ge 24 ]; then
  {
    echo ""
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Monitor done (${COUNT} closes captured, ${ELAPSED_H}h elapsed). Removing from crontab."
  } >> "$OUT_FILE"
  crontab -l 2>/dev/null | grep -v 'monitor_non_jtvo_closes' | crontab -
  rm -f "$STATE_FILE" "$COUNT_FILE"
  exit 0
fi

LOG="logs/agent-$(date -u +%Y-%m-%d).log"
[ -f "$LOG" ] || exit 0

# Find closes since last run window (35 min lookback to overlap with 30-min cron interval)
CUTOFF="$(date -u -d '35 minutes ago' +%Y-%m-%dT%H:%M)"

python3 - <<PY >> "$OUT_FILE" 2>&1
import re, json, sys
from pathlib import Path
from datetime import datetime

log = Path("$LOG")
cutoff = "$CUTOFF"
count_file = Path("$COUNT_FILE")
seen_file = Path("checkpoints/non_jtvo_closes.seen")
already_seen = set(seen_file.read_text().splitlines()) if seen_file.exists() else set()

CLOSE_RE = re.compile(r"\[([^\]]+)\] \[CLOSE\] Closed PnL from API: pnl=(-?\d+\.\d+) USD \((-?\d+\.\d+)%\)")
MARKED_RE = re.compile(r"\[([^\]]+)\] \[STATE\] Position (\w+) marked closed: (.+)$")

lines = log.read_text(errors="ignore").splitlines()
recent_marked = []  # (ts, addr, reason)
for line in lines:
    if line < f"[{cutoff}": continue
    m = MARKED_RE.search(line)
    if m: recent_marked.append((m.group(1), m.group(2), m.group(3).strip()))

count = int(count_file.read_text().strip())
new_seen = []

for line in lines:
    if line < f"[{cutoff}": continue
    m = CLOSE_RE.search(line)
    if not m: continue
    ts, pnl_usd, pnl_pct = m.group(1), float(m.group(2)), float(m.group(3))
    # Match to most recent marked-close within 60s
    addr, reason = None, "?"
    ts_dt = datetime.fromisoformat(ts.replace("Z","+00:00")).replace(tzinfo=None)
    for mts, maddr, mreason in recent_marked:
        mts_dt = datetime.fromisoformat(mts.replace("Z","+00:00")).replace(tzinfo=None)
        if abs((ts_dt - mts_dt).total_seconds()) <= 60:
            addr, reason = maddr, mreason
            break
    key = f"{ts}|{addr}"
    if key in already_seen: continue
    new_seen.append(key)

    # Look up pool name + peak from state.json
    pool_name, peak = "?", "?"
    try:
        s = json.load(open("state.json"))
        if addr and addr in s.get("positions", {}):
            p = s["positions"][addr]
            pool_name = p.get("pool_name") or "?"
            pk = p.get("peak_pnl_pct")
            peak = f"{pk:.2f}%" if pk is not None else "?"
    except Exception: pass

    if "JTVO" in pool_name.upper():
        continue

    count += 1
    print(f"\n[{ts}] CLOSE #{count}/4: {pool_name}")
    print(f"  realized: ${pnl_usd} ({pnl_pct}%)  peak={peak}")
    print(f"  reason: {reason[:120]}")
    sys.stdout.flush()
    if count >= 4: break

if new_seen:
    with seen_file.open("a") as f:
        for k in new_seen: f.write(k + "\n")
count_file.write_text(str(count))
PY
