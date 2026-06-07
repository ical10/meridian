#!/bin/bash
# Auto-switch to dump_spot at scheduled US-hour time.
# Triggered via `at`. Applies strategy, restarts bot, sends Telegram confirmation.

set -e
cd /root/meridian/meridian
mkdir -p checkpoints

OUT=checkpoints/dump_spot_switch.log
TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2 | awk '{print $1}')
TG_CHAT=$(python3 -c "import json; print(json.load(open('user-config.json'))['telegramChatId'])")

{
  echo "═══════════════════════════════════════════════════════════════════"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Switching to dump_spot (scheduled)"
  echo "═══════════════════════════════════════════════════════════════════"

  # Apply strategy
  node -e "
import('./strategy-library.js').then(m => {
  const r = m.setActiveStrategy({ id: 'dump_spot' });
  console.log('active:', r.active);
  for (const c of r.config_overrides_applied) {
    if (JSON.stringify(c.before) !== JSON.stringify(c.after))
      console.log('  '+c.key+': '+JSON.stringify(c.before)+' → '+JSON.stringify(c.after));
  }
});
" 2>&1

  # Restart bot
  OLD_PID=$(pgrep -f "node index.js" | head -1)
  echo "killing old PID: $OLD_PID"
  kill "$OLD_PID" 2>/dev/null || true
  sleep 3
  nohup ./restart.sh > /tmp/restart_dumpswitch.out 2>&1 &
  sleep 10
  NEW_PID=$(pgrep -f "node index.js" | head -1)
  echo "new PID: $NEW_PID"
} >> "$OUT" 2>&1

# Telegram notification
SUMMARY=$(python3 << 'PY'
import json
u = json.load(open("user-config.json"))
d = json.load(open("strategy-library.json"))
lines = [
    "🔄 Auto-switched to dump_spot",
    f"Active: {d.get('active')}",
    f"TP/SL: {u.get('takeProfitPct')} / {u.get('stopLossPct')}",
    f"Trailing: trig {u.get('trailingTriggerPct')} / drop {u.get('trailingDropPct')}",
    f"Filters: vol≥{u.get('minVolume')}, fees≥{u.get('minTokenFeesSol')}, age {u.get('minTokenAgeHours')}-{u.get('maxTokenAgeHours')}h, ath {u.get('athFilterPct')}%",
    f"Discord: {u.get('useDiscordSignals')} ({u.get('discordSignalMode')})",
    "",
    "2h checkpoint scheduled at 16:00 UTC",
]
print("\n".join(lines))
PY
)

if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=${SUMMARY}" > /dev/null 2>&1 || true
fi

echo "[switch done: $(date -u +%H:%M:%SZ)]" >> "$OUT"
