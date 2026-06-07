#!/bin/bash
# 24h checkpoint after enabling maxFeeActiveTvlRatio=1.0.
# Activation: 2026-06-01 ~21:17 UTC.
# Triggered once via `at` at 2026-06-02 21:17 UTC.
# Sends Telegram summary + writes detailed log.

set -e
cd /root/meridian/meridian
mkdir -p checkpoints

OUT=checkpoints/max_fee_tvl_24h.log
WINDOW_START="2026-06-01T21:17"
TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2 | awk '{print $1}')
TG_CHAT=$(python3 -c "import json; print(json.load(open('user-config.json'))['telegramChatId'])")

python3 - <<PY >> "$OUT" 2>&1
import json, re
from pathlib import Path
from datetime import datetime
from collections import defaultdict

WIN = "$WINDOW_START"
win_dt = datetime.fromisoformat(WIN)

# Collect window log content across today and yesterday log files
content = ""
for f in sorted(Path("logs").glob("agent-2026-*.log")):
    content += f.read_text(errors="ignore") + "\n"
recent = [l for l in content.splitlines() if l >= f"[{WIN}"]
text = "\n".join(recent)

# Stats
CLOSE_RE = re.compile(r"\[CLOSE\] Closed PnL from API: pnl=(-?\d+\.\d+) USD \((-?\d+\.\d+)%\)")
closes = CLOSE_RE.findall(text)
deploys = text.count("🚀 **DEPLOYED**")
deploy_failed = text.count("🚀 **DEPLOY FAILED**")
short_circuits = text.count("short-circuit")
screening_cycles = text.count("Starting screening cycle")
max_rejects = text.count("above maxFeeActiveTvlRatio")

total_pnl = sum(float(p[0]) for p in closes)
wins = sum(1 for p in closes if float(p[0]) > 0)
losses = sum(1 for p in closes if float(p[0]) < 0)

# Average fee/TVL of deployed positions in the window
s = json.load(open("state.json"))
window_deploys = []
for k, p in s["positions"].items():
    dep = p.get("deployed_at")
    if not dep: continue
    try:
        dt = datetime.fromisoformat(dep.replace("Z","+00:00")).replace(tzinfo=None)
        if dt >= win_dt:
            window_deploys.append(p)
    except: pass
if window_deploys:
    fee_tvls = [p.get("initial_fee_tvl_24h") for p in window_deploys if p.get("initial_fee_tvl_24h") is not None]
    avg_fee_tvl = sum(fee_tvls) / len(fee_tvls) if fee_tvls else None
    max_fee_tvl = max(fee_tvls) if fee_tvls else None
    in_target_range = sum(1 for f in fee_tvls if 0.2 <= f <= 1.0)
else:
    avg_fee_tvl = None
    max_fee_tvl = None
    in_target_range = 0

print("═══════════════════════════════════════════════════════════════════")
print(f"[{datetime.utcnow().isoformat()[:19]}Z] maxFeeActiveTvlRatio 24h checkpoint")
print(f"  Window: since {WIN} (24h)")
print(f"  Filter: minFeeActiveTvlRatio=0.2, maxFeeActiveTvlRatio=1.0")
print("═══════════════════════════════════════════════════════════════════")
print()
print("--- ACTIVITY ---")
print(f"  screening cycles: {screening_cycles}")
print(f"  short-circuits:   {short_circuits}")
print(f"  deploys:          {deploys}")
print(f"  deploy_failed:    {deploy_failed}")
print(f"  closes:           {len(closes)} ({wins} wins, {losses} losses)")
print(f"  net PnL:          \${total_pnl:+.2f}")
print()
print("--- FILTER IMPACT ---")
print(f"  pools rejected by maxFeeActiveTvlRatio: {max_rejects}")
print()
print("--- DEPLOYED POSITIONS' FEE/TVL DISTRIBUTION ---")
print(f"  count:            {len(window_deploys)}")
if avg_fee_tvl is not None:
    print(f"  avg fee/TVL:      {avg_fee_tvl:.3f}")
    print(f"  max fee/TVL:      {max_fee_tvl:.3f}")
    print(f"  in target [0.2, 1.0]: {in_target_range} ({100*in_target_range/len(window_deploys):.0f}%)")
else:
    print(f"  (no deploys in window)")
print()
print("--- BIGGEST LOSSES IN WINDOW ---")
losses_list = sorted([(float(p[0]), float(p[1])) for p in closes if float(p[0]) < 0])
for usd, pct in losses_list[:5]:
    print(f"  \${usd:+.2f} ({pct:+.2f}%)")

# Telegram summary
summary_lines = [
    "🔔 maxFeeActiveTvlRatio 24h check",
    f"24h since 2026-06-01 21:17 UTC",
    "",
    f"Deploys: {deploys} | Closes: {len(closes)} ({wins}W/{losses}L)",
    f"Net PnL: \${total_pnl:+.2f}",
    f"Filter rejects: {max_rejects} pools blocked by cap",
]
if avg_fee_tvl is not None:
    summary_lines.append(f"Avg fee/TVL of deploys: {avg_fee_tvl:.3f}")
summary_lines.extend(["", "Full log: checkpoints/max_fee_tvl_24h.log"])
print()
print("--- TELEGRAM ---")
print("\n".join(summary_lines))

# Write the Telegram message to a file for the bash script to pick up
with open("/tmp/_max_fee_tg_summary.txt", "w") as f:
    f.write("\n".join(summary_lines))
PY

# Send Telegram
if [ -f /tmp/_max_fee_tg_summary.txt ] && [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  TG_TEXT=$(cat /tmp/_max_fee_tg_summary.txt)
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=${TG_TEXT}" > /dev/null 2>&1 || true
  rm -f /tmp/_max_fee_tg_summary.txt
fi

echo "[done: $(date -u +%H:%M:%SZ)]" >> "$OUT"
