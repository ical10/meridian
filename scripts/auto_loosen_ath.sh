#!/bin/bash
# Auto-loosen dump_spot's athFilterPct from -40 to -30 if no deploys in the last 60 min.
# Yunus math: -50% dump + 10-20% retracement = -30% to -40% net from ATH.
# Current -40 only catches the deeper half; -30 captures the full Yunus zone.
# Triggered once via `at` at 15:55 UTC. Decision based on actual state.json deploys
# within the configured window (more robust than log greps that can miss reloads).

set -e
cd /root/meridian/meridian

OUT=checkpoints/auto_loosen_ath.log
TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2 | awk '{print $1}')
TG_CHAT=$(python3 -c "import json; print(json.load(open('user-config.json'))['telegramChatId'])")
WINDOW_START_ISO="2026-06-01T14:55:00Z"

DEPLOY_COUNT=$(python3 - <<PY
import json
from datetime import datetime
def piso(x):
    if not x: return None
    try: return datetime.fromisoformat(x.replace("Z","+00:00")).replace(tzinfo=None)
    except: return None
s = json.load(open("state.json"))
cutoff = datetime.fromisoformat("$WINDOW_START_ISO".replace("Z","+00:00")).replace(tzinfo=None)
count = sum(1 for p in s["positions"].values()
            if piso(p.get("deployed_at")) and piso(p.get("deployed_at")) >= cutoff)
print(count)
PY
)

{
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Auto-loosen ath check"
  echo "  window: since $WINDOW_START_ISO (60 min)"
  echo "  deploys in window: $DEPLOY_COUNT"
  echo "═══════════════════════════════════════════════════════════════════"
} >> "$OUT" 2>&1

if [ "$DEPLOY_COUNT" -gt 0 ]; then
  echo "Deploys happened ($DEPLOY_COUNT) — no loosening needed." >> "$OUT"
  SUMMARY="✓ Auto-loosen check (15:55 UTC): $DEPLOY_COUNT deploy(s) in last 60min. athFilterPct stays at -40."
else
  echo "Zero deploys in window — loosening athFilterPct -40 → -30" >> "$OUT"

  # Update user-config.json (live config)
  python3 - <<PY >> "$OUT" 2>&1
import json
u = json.load(open("user-config.json"))
old = u.get("athFilterPct")
u["athFilterPct"] = -30
with open("user-config.json","w") as f: json.dump(u,f,indent=2)
print(f"  user-config.json athFilterPct: {old} → {u['athFilterPct']}")
PY

  # Update strategy-library.json dump_spot — config_overrides AND descriptive vocab.
  # Keep the prompt-injected text aligned with the actual filter so the LLM's mental
  # model matches operational reality (otherwise it may reject candidates that pass
  # the loosened filter but don't fit the original -40/-50% description).
  python3 - <<PY >> "$OUT" 2>&1
import json
from datetime import datetime, timezone
d = json.load(open("strategy-library.json"))
ds = d["strategies"]["dump_spot"]
old_filter = ds["config_overrides"].get("athFilterPct")
ds["config_overrides"]["athFilterPct"] = -30

# Vocab updates — match the loosened filter
ds["token_criteria"]["notes"] = (
    "Established mid-cap tokens (12-48h old) that dumped ~50% from ATH and are now "
    "in the retracement bounce phase (10-20% off the bottom), putting them at -30% "
    "to -40% net from ATH. We enter on the bounce, not the dump."
)
ds["entry"]["condition"] = (
    "HARD REQUIREMENTS: (a) Token at least 30% below ATH (captures the full Yunus "
    "retracement zone: -50% dump retraced 10-20% = -30% to -40% net). (b) Recent 1h "
    "action is POSITIVE — the retracement bounce, ideally +5% to +20%. (c) NOT "
    "currently dumping in the 1h window. (d) volume_window >= 20000, organic >= 60, "
    "fee/TVL >= 0.20."
)
ds["best_for"] = (
    "Established mid-cap memecoins that dumped ~50% and are bouncing back 10-20% "
    "(now at -30% to -40% from ATH). Enter on the bounce, not the dump."
)
ds["updated_at"] = datetime.now(timezone.utc).isoformat()

with open("strategy-library.json","w") as f: json.dump(d,f,indent=2)
print(f"  strategy-library.json dump_spot.athFilterPct: {old_filter} → {ds['config_overrides']['athFilterPct']}")
print(f"  + vocab fields rewritten to match (-30% threshold)")
PY

  # Restart bot
  OLD_PID=$(pgrep -f "node index.js" | head -1 || echo "?")
  echo "  killing old PID: $OLD_PID" >> "$OUT"
  kill "$OLD_PID" 2>/dev/null || true
  sleep 3
  nohup ./restart.sh > /tmp/restart_loosen.out 2>&1 &
  sleep 10
  NEW_PID=$(pgrep -f "node index.js" | head -1 || echo "?")
  echo "  new PID: $NEW_PID" >> "$OUT"

  SUMMARY="🔄 Auto-loosen fired (15:55 UTC): 0 deploys in last 60min → athFilterPct -40 → -30. Bot restarted (PID $NEW_PID). Updated in user-config.json AND dump_spot preset."
fi

# Telegram notify
if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=${SUMMARY}" > /dev/null 2>&1 || true
fi

echo "[done: $(date -u +%H:%M:%SZ)]" >> "$OUT"
