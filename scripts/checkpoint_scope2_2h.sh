#!/bin/bash
# 2h checkpoint after dump_spot Scope 2 loosening at 2026-06-03 03:07 UTC.
# Reports whether unblocking minMcap=100k + maxTokenAgeHours=null produced deploys.

set -e
cd /root/meridian/meridian
mkdir -p checkpoints

OUT=checkpoints/scope2_2h.log
WINDOW_START="2026-06-03T03:07"
TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2 | awk '{print $1}')
TG_CHAT=$(python3 -c "import json; print(json.load(open('user-config.json'))['telegramChatId'])")

python3 - <<PY >> "$OUT" 2>&1
import json, re
from pathlib import Path
from datetime import datetime

WIN = "$WINDOW_START"
win_dt = datetime.fromisoformat(WIN)

content = ""
for f in sorted(Path("logs").glob("agent-2026-*.log")):
    content += f.read_text(errors="ignore") + "\n"
recent_lines = [l for l in content.splitlines() if l >= f"[{WIN}"]
text = "\n".join(recent_lines)

CLOSE_RE = re.compile(r"\[CLOSE\] Closed PnL from API: pnl=(-?\d+\.\d+) USD \((-?\d+\.\d+)%\)")
closes = CLOSE_RE.findall(text)
deploys = text.count("🚀 **DEPLOYED**")
no_deploys = text.count("⛔ **NO DEPLOY**") + text.count("⛔ NO DEPLOY")
short_circuits = text.count("short-circuit")
screening_cycles = text.count("Starting screening cycle")

# Filter funnel
disc_filtered = len(re.findall(r"Discord signal filtered:.*below", text))
mcap_blocks = len(re.findall(r"below minMcap", text))
tvl_blocks = len(re.findall(r"below minTvl|tvl below", text))
ath_blocks = len(re.findall(r"athFilterPct|above ATH filter", text))
total_pnl = sum(float(p[0]) for p in closes)

# Open positions snapshot
s = json.load(open("state.json"))
opens = [(k,p) for k,p in s["positions"].items() if not p.get("closed_at")]
opens_str = ", ".join(f"{p.get('pool_name')} {p.get('peak_pnl_pct') or 0:.1f}%" for _,p in opens) or "none"

print("═══════════════════════════════════════════════════════════════════")
print(f"[{datetime.utcnow().isoformat()[:19]}Z] Scope 2 — 2h checkpoint")
print(f"  Window: since {WIN}")
print(f"  Loosenings applied: maxTokenAgeHours=null, minMcap=100000")
print("═══════════════════════════════════════════════════════════════════")
print()
print("--- ACTIVITY ---")
print(f"  screening cycles:    {screening_cycles}")
print(f"  short-circuits:      {short_circuits}")
print(f"  NO DEPLOY outcomes:  {no_deploys}    ← if >0, Gate 1 is unblocked")
print(f"  deploys:             {deploys}    ← the goal")
print(f"  closes:              {len(closes)}, net \${total_pnl:+.2f}")
print()
print("--- FILTER FUNNEL ---")
print(f"  discord signals filtered: {disc_filtered}")
print(f"  below minMcap:            {mcap_blocks}")
print(f"  below minTvl:             {tvl_blocks}")
print(f"  ATH filter blocks:        {ath_blocks}")
print()
print(f"--- OPEN POSITIONS ---")
print(f"  {opens_str}")

# Verdict
print()
print("--- VERDICT ---")
if deploys > 0:
    print(f"  ✓ Scope 2 worked — {deploys} deploy(s) in 2h window")
elif no_deploys > 0:
    print(f"  ◐ Candidates reaching LLM ({no_deploys} NO DEPLOY) — Gate 1 unblocked, but Gate 2 (LLM) rejecting")
    print(f"    Next move: investigate WHY skipped (pool memory? narrative?), or loosen further")
else:
    print(f"  ✗ Still 0 candidates reaching LLM — Scope 2 wasn't enough")
    print(f"    Next move: drop minMcap further to act on CLAWD-class discord signals, or switch back to momentum_spot_pump")

# Telegram summary
lines = [
    "🔔 Scope 2 — 2h checkpoint",
    f"dump_spot since 03:07 UTC",
    "",
    f"Screening: {screening_cycles} cycles",
    f"NO DEPLOY: {no_deploys}",
    f"Deploys:   {deploys}",
    f"Closes:    {len(closes)} (\${total_pnl:+.2f})",
    "",
    f"Open: {opens_str}",
    "",
    "Full log: checkpoints/scope2_2h.log",
]
with open("/tmp/_scope2_tg.txt","w") as f: f.write("\n".join(lines))
PY

if [ -f /tmp/_scope2_tg.txt ] && [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  TG_TEXT=$(cat /tmp/_scope2_tg.txt)
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=${TG_TEXT}" > /dev/null 2>&1 || true
  rm -f /tmp/_scope2_tg.txt
fi

echo "[done: $(date -u +%H:%M:%SZ)]" >> "$OUT"
