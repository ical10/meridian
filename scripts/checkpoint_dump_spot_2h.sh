#!/bin/bash
# 2h checkpoint after dump_spot activation (2026-06-01 03:59:37 UTC)
# Triggered once via `at`. Sends Telegram summary + writes detailed log.
# Captures: deploys, closes, screening NO-DEPLOY reasons, discord activity, cooldowns.

set -e
cd /root/meridian/meridian
mkdir -p checkpoints

OUT=checkpoints/dump_spot_2h.log
LOG="logs/agent-$(date -u +%Y-%m-%d).log"
WINDOW_START="2026-06-01T03:59"

# Telegram creds (read from .env / user-config.json)
TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2 | awk '{print $1}')
TG_CHAT=$(python3 -c "import json; print(json.load(open('user-config.json'))['telegramChatId'])")

{
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] dump_spot 2h checkpoint"
  echo "Window: since ${WINDOW_START} (strategy switch time)"
  echo "═══════════════════════════════════════════════════════════════════"

  echo ""
  echo "--- ACTIVE STRATEGY ---"
  python3 -c "
import json
d=json.load(open('strategy-library.json'))
print(f'  active: {d.get(\"active\")}')"

  echo ""
  echo "--- OPEN POSITIONS ---"
  python3 -c "
import json
s=json.load(open('state.json'))
opens=[(k,p) for k,p in s['positions'].items() if not p.get('closed_at')]
if not opens: print('  (none)')
for k,p in opens:
    peak=p.get('peak_pnl_pct'); peak_s=f'{peak:.2f}%' if peak is not None else 'N/A'
    print(f'  {p.get(\"pool_name\")} deployed={p.get(\"deployed_at\",\"\")[:19]} peak={peak_s} amt={p.get(\"amount_sol\")}SOL')"

  echo ""
  echo "--- DEPLOYS IN WINDOW ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -E "🚀 \*\*DEPLOYED\*\*|\\[DEPLOY\\] Pool:" | tail -20 || echo "  (none)"

  echo ""
  echo "--- CLOSES IN WINDOW ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -E "Closed PnL from API|marked closed" | tail -15 || echo "  (none)"

  echo ""
  echo "--- NO-DEPLOY REASONS (dump_spot filter behavior) ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -B 1 -A 5 "⛔ \*\*NO DEPLOY\*\*\|WHY SKIPPED" | tail -50 || echo "  (none)"

  echo ""
  echo "--- DISCORD SIGNAL ACTIVITY ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -iE "discord|signals/discord|discord_signal" | tail -10 || echo "  (no discord events yet — server may be quiet)"

  echo ""
  echo "--- NEW COOLDOWN ADDITIONS ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -E "cooldown" | sort -u | tail -15 || echo "  (none)"

  echo ""
  echo "--- SCREENING CYCLES COUNT ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -cE "Starting screening cycle" | xargs -I{} echo "  cycles fired: {}"

  echo ""
  echo "--- ERRORS / WARNINGS ---"
  awk -v c="[$WINDOW_START" '$0 >= c' "$LOG" | grep -E "CRON_ERROR|WALLET_ERROR|Agent loop error|HIVEMIND_WARN" | head -10 || echo "  (none)"

  echo ""
  echo "--- NON-JTVO CLOSE MONITOR STATUS ---"
  if [ -f checkpoints/non_jtvo_closes.count ]; then
    echo "  captured: $(cat checkpoints/non_jtvo_closes.count)/4"
  else
    echo "  (monitor self-removed or not started)"
  fi
} >> "$OUT" 2>&1

# Build short Telegram summary
SUMMARY=$(python3 << 'EOF'
import json, re
from pathlib import Path

s = json.load(open("state.json"))
d = json.load(open("strategy-library.json"))
log = Path(f"logs/agent-2026-06-01.log")
content = log.read_text(errors="ignore") if log.exists() else ""

# Window
WIN = "[2026-06-01T03:59"

# Open positions
opens = [(k,p) for k,p in s["positions"].items() if not p.get("closed_at")]
opens_str = ", ".join(f"{p.get('pool_name')} {p.get('peak_pnl_pct') or 0:.1f}%" for _,p in opens) or "none"

# Deploys + closes in window
recent = [l for l in content.splitlines() if l >= WIN]
deploys = sum(1 for l in recent if "🚀 **DEPLOYED**" in l)
closes = re.findall(r"Closed PnL from API: pnl=(-?\d+\.\d+) USD \((-?\d+\.\d+)%\)", "\n".join(recent))
total_pnl = sum(float(p[0]) for p in closes)
screenings = sum(1 for l in recent if "Starting screening cycle" in l)
no_deploys = sum(1 for l in recent if "⛔ **NO DEPLOY**" in l)
discord_hits = sum(1 for l in recent if "discord_signal" in l.lower() or "Discord signal" in l)

lines = [
    "🔔 dump_spot 2h checkpoint",
    f"Active: {d.get('active')}",
    f"Open: {opens_str}",
    f"Window stats:",
    f"  • {screenings} screening cycles, {no_deploys} no-deploys, {deploys} deploys",
    f"  • {len(closes)} closes, net ${total_pnl:.2f}",
    f"  • Discord signal events: {discord_hits}",
    "",
    "Full log: checkpoints/dump_spot_2h.log",
]
print("\n".join(lines))
EOF
)

# Send Telegram
if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" \
    --data-urlencode "text=${SUMMARY}" > /dev/null 2>&1 || true
fi

echo "[checkpoint sent: $(date -u +%H:%M:%SZ)]" >> "$OUT"
