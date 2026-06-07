#!/bin/bash
# Checkpoint 2h after dump_spot v2 switch (scheduled separately via at).
# Sends Telegram + writes detailed log.

set -e
cd /root/meridian/meridian
mkdir -p checkpoints

OUT=checkpoints/dump_spot_v2_checkpoint.log
TODAY="$(date -u +%Y-%m-%d)"
LOG="logs/agent-${TODAY}.log"
WINDOW_START="${TODAY}T14:00"
export WINDOW_START

TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2 | awk '{print $1}')
TG_CHAT=$(python3 -c "import json; print(json.load(open('user-config.json'))['telegramChatId'])")

{
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] dump_spot v2 — 2h checkpoint"
  echo "Window: since ${WINDOW_START}"
  echo "═══════════════════════════════════════════════════════════════════"

  echo ""
  echo "--- ACTIVE STRATEGY ---"
  python3 -c "import json; d=json.load(open('strategy-library.json')); print(f'  active: {d.get(\"active\")}')"

  echo ""
  echo "--- OPEN POSITIONS ---"
  python3 -c "
import json
s=json.load(open('state.json'))
opens=[(k,p) for k,p in s['positions'].items() if not p.get('closed_at')]
if not opens: print('  (none)')
for k,p in opens:
    peak=p.get('peak_pnl_pct'); peak_s=f'{peak:.2f}%' if peak is not None else 'N/A'
    print(f'  {p.get(\"pool_name\")} deployed={p.get(\"deployed_at\",\"\")[:19]} peak={peak_s}')"

  echo ""
  echo "--- DEPLOYS IN WINDOW ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -E "🚀 \*\*DEPLOYED\*\*|\\[DEPLOY\\] Pool:" | tail -20 || echo "  (none)"

  echo ""
  echo "--- CLOSES IN WINDOW ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -E "Closed PnL from API" | tail -15 || echo "  (none)"

  echo ""
  echo "--- DISCORD SIGNAL ACTIVITY ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -iE "discord_signal|signals/discord|Discord signal" | tail -10 || echo "  (no discord events)"

  echo ""
  echo "--- NO-DEPLOY REASONS (sample) ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -A 4 "WHY SKIPPED" | tail -30 || echo "  (none)"

  echo ""
  echo "--- SCREENING CYCLES ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -c "Starting screening cycle" | xargs -I{} echo "  cycles fired: {}"
} >> "$OUT" 2>&1

# Telegram summary
SUMMARY=$(python3 << 'PY'
import json, os, re
from pathlib import Path
window_start = os.environ.get("WINDOW_START", "")
today = window_start[:10]
s = json.load(open("state.json"))
d = json.load(open("strategy-library.json"))
log = Path(f"logs/agent-{today}.log")
content = log.read_text(errors="ignore") if log.exists() else ""
WIN = f"[{window_start}"
recent = [l for l in content.splitlines() if l >= WIN]
opens = [(k,p) for k,p in s["positions"].items() if not p.get("closed_at")]
opens_str = ", ".join(f"{p.get('pool_name')} {p.get('peak_pnl_pct') or 0:.1f}%" for _,p in opens) or "none"
deploys = sum(1 for l in recent if "🚀 **DEPLOYED**" in l)
closes = re.findall(r"Closed PnL from API: pnl=(-?\d+\.\d+) USD \((-?\d+\.\d+)%\)", "\n".join(recent))
total_pnl = sum(float(p[0]) for p in closes)
wins = sum(1 for p in closes if float(p[0]) > 0)
screenings = sum(1 for l in recent if "Starting screening cycle" in l)
discord_hits = sum(1 for l in recent if "discord_signal" in l.lower())
lines = [
    "🔔 dump_spot v2 — 2h checkpoint",
    f"Active: {d.get('active')}",
    f"Open: {opens_str}",
    f"Window 14:00-16:00 UTC:",
    f"  • {screenings} screening cycles, {deploys} deploys",
    f"  • {len(closes)} closes ({wins} wins), net ${total_pnl:.2f}",
    f"  • Discord signal events: {discord_hits}",
    "",
    "Full log: checkpoints/dump_spot_v2_checkpoint.log",
]
print("\n".join(lines))
PY
)

if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=${SUMMARY}" > /dev/null 2>&1 || true
fi

echo "[checkpoint sent: $(date -u +%H:%M:%SZ)]" >> "$OUT"
