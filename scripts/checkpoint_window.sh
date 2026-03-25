#!/bin/bash
# Performance checkpoint over a configurable window.
# Usage: WINDOW_START=2026-06-09T16:38 LABEL="24h" ./checkpoint_window.sh
# Sends Telegram summary + writes detailed log.

set -e
cd /root/meridian/meridian
mkdir -p checkpoints

LABEL="${LABEL:-window}"
WIN_START="${WINDOW_START:-$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M)}"
OUT="checkpoints/perf_${LABEL}.log"
TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2 | awk '{print $1}')
TG_CHAT=$(python3 -c "import json; print(json.load(open('user-config.json'))['telegramChatId'])")

python3 - <<PY >> "$OUT" 2>&1
import json, re, os
from pathlib import Path
from datetime import datetime, timezone
from collections import Counter

label = "$LABEL"
win_start = "$WIN_START"
win_dt = datetime.fromisoformat(win_start)

# Collect all closes since window start
CLOSE_RE = re.compile(r"\[([^\]]+)\] \[CLOSE\] Closed PnL from API: pnl=(-?\d+\.\d+) USD \((-?\d+\.\d+)%\)")
MARKED_RE = re.compile(r"\[([^\]]+)\] \[STATE\] Position (\w+) marked closed: (.+)$")
close_pnl = {}
for f in sorted(Path("logs").glob("agent-2026-*.log")):
    pending = []
    for line in f.read_text(errors="ignore").splitlines():
        m = MARKED_RE.search(line)
        if m:
            ts = datetime.fromisoformat(m.group(1).replace("Z","+00:00")).replace(tzinfo=None)
            if ts >= win_dt:
                pending.append((ts, m.group(2), m.group(3).strip()))
        m = CLOSE_RE.search(line)
        if m:
            ts = datetime.fromisoformat(m.group(1).replace("Z","+00:00")).replace(tzinfo=None)
            if ts < win_dt: continue
            for i,(pts,paddr,reason) in enumerate(pending):
                if abs((ts-pts).total_seconds()) <= 60:
                    close_pnl[paddr] = {"ts": ts, "pnl_usd": float(m.group(2)), "pnl_pct": float(m.group(3)), "reason": reason}
                    pending.pop(i); break

closes = list(close_pnl.values())
wins = [c for c in closes if c["pnl_usd"] > 0]
losses = [c for c in closes if c["pnl_usd"] < 0]
total = sum(c["pnl_usd"] for c in closes)
wr = 100*len(wins)/len(closes) if closes else 0

# Open positions
s = json.load(open("state.json"))
opens = [(k,p) for k,p in s["positions"].items() if not p.get("closed_at")]

# Reason breakdown
reason_cat = Counter()
for c in closes:
    r = c["reason"].lower()
    if "stop loss" in r: reason_cat["STOP_LOSS"] += 1
    elif "trailing" in r: reason_cat["TRAILING_TP"] += 1
    elif "take profit" in r: reason_cat["TP"] += 1
    elif "out of range" in r or "pumped" in r: reason_cat["OOR"] += 1
    elif "dead pool" in r: reason_cat["DEAD"] += 1
    elif "low yield" in r: reason_cat["LOW_YIELD"] += 1
    else: reason_cat["OTHER"] += 1

# Active strategy
d = json.load(open("strategy-library.json"))
u = json.load(open("user-config.json"))

print("═" * 67)
print(f"[{datetime.utcnow().isoformat()[:19]}Z] PERFORMANCE CHECKPOINT — {label}")
print(f"  window: since {win_start}")
print(f"  strategy: {d.get('active')}")
print("═" * 67)
print()
print("--- CLOSES ---")
print(f"  total:   {len(closes)}  (wins {len(wins)}, losses {len(losses)})  WR={wr:.1f}%")
print(f"  net:     \${total:+.2f}")
if closes:
    best = max(closes, key=lambda c: c["pnl_usd"])
    worst = min(closes, key=lambda c: c["pnl_usd"])
    print(f"  best:    \${best['pnl_usd']:+.2f} ({best['pnl_pct']:+.2f}%)")
    print(f"  worst:   \${worst['pnl_usd']:+.2f} ({worst['pnl_pct']:+.2f}%)")
print()
print("--- EXIT REASON BREAKDOWN ---")
for k, n in reason_cat.most_common():
    print(f"  {k}: {n}")
print()
print("--- CURRENT STATE ---")
print(f"  open positions: {len(opens)}")
for k,p in opens[:3]:
    print(f"    {p.get('pool_name')} peak={p.get('peak_pnl_pct')}% deployed={p.get('deployed_at','')[:19]}")
print()
print(f"--- CONFIG SNAPSHOT ---")
for k in ['strategy','category','takeProfitPct','stopLossPct','trailingDropPct','feeActiveTvlBands','minVolume','minTvl','maxTvl','minMcap','deployAmountSol']:
    print(f"  {k}: {u.get(k)}")

# Telegram summary
tg_lines = [
    f"📊 Perf checkpoint {label}",
    f"Strategy: {d.get('active')}",
    f"",
    f"Closes: {len(closes)} ({len(wins)}W/{len(losses)}L)  WR={wr:.0f}%",
    f"Net:    \${total:+.2f}",
]
if closes:
    tg_lines.append(f"Best:   \${best['pnl_usd']:+.2f} ({best['pnl_pct']:+.2f}%)")
    tg_lines.append(f"Worst:  \${worst['pnl_usd']:+.2f} ({worst['pnl_pct']:+.2f}%)")
tg_lines.append(f"")
tg_lines.append(f"Open: {len(opens)}")
tg_lines.append(f"")
tg_lines.append(f"Full log: checkpoints/perf_{label}.log")
with open("/tmp/_perf_tg.txt","w") as f:
    f.write("\n".join(tg_lines))
PY

if [ -f /tmp/_perf_tg.txt ] && [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  TG_TEXT=$(cat /tmp/_perf_tg.txt)
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=${TG_TEXT}" > /dev/null 2>&1 || true
  rm -f /tmp/_perf_tg.txt
fi

echo "[done: $(date -u +%H:%M:%SZ)]" >> "$OUT"
