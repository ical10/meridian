#!/bin/bash
# One-shot checkpoint scheduled for 2026-05-29.
# Validates effect of smart-wallet + 6h-age filters enabled at 2026-05-26 21:01 UTC.
# Output to /root/meridian/meridian/checkpoints/2026-05-29-filter-validation.txt.
# Self-removes from crontab after running.

set -e
cd /root/meridian/meridian

OUT="checkpoints/2026-05-29-filter-validation.txt"
FILTER_ENABLE="2026-05-26T21:01"

{
  echo "============================================================"
  echo "Meridian Filter Validation Checkpoint"
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Filter enable cutoff: ${FILTER_ENABLE} UTC"
  echo "Active filters:"
  echo "  - requireSmartWallets: true  (anti-rug)"
  echo "  - minTokenAgeHours:    6     (skip very-fresh tokens)"
  echo "============================================================"
  echo ""

  echo "## OVERALL ANALYZER OUTPUT — closes since filter enable"
  python3 scripts/analyze_performance.py --since 2026-05-26 2>&1
  echo ""

  echo "============================================================"
  echo "## FILTER-SPECIFIC DIAGNOSTICS"
  echo "============================================================"
  python3 - <<'PYEOF'
import re, json
from datetime import datetime, timedelta
from pathlib import Path

FILTER_ENABLE = datetime(2026, 5, 26, 21, 1)
def piso(x): return datetime.fromisoformat(x.replace('Z','+00:00')).replace(tzinfo=None)

CLOSE_RE  = re.compile(r"\[([^\]]+)\] \[CLOSE\] Closed PnL from API: pnl=(-?\d+\.\d+) USD \((-?\d+\.\d+)%\)")
MARKED_RE = re.compile(r"\[([^\]]+)\] \[STATE\] Position (\w+) marked closed: (.+)$")

# Collect closes across all logs
pairs = []
pending = []
for f in sorted(Path('logs').glob('agent-2026-*.log')):
    for line in f.open(errors='ignore'):
        m = MARKED_RE.search(line)
        if m:
            pending.append((piso(m.group(1)), m.group(2), m.group(3).strip())); continue
        m = CLOSE_RE.search(line)
        if m:
            ts = piso(m.group(1))
            for i, (pts, addr, reason) in enumerate(pending):
                if abs((ts - pts).total_seconds()) <= 60:
                    pairs.append((ts, addr, reason, float(m.group(2)), float(m.group(3))))
                    pending.pop(i); break

# Pre-filter baseline = 7 days BEFORE filter enable
pre_start = FILTER_ENABLE - timedelta(days=7)
pre = [p for p in pairs if pre_start <= p[0] < FILTER_ENABLE]
post = [p for p in pairs if p[0] >= FILTER_ENABLE]

def summarize(label, lst):
    if not lst:
        print(f"{label}: no closes in window")
        return
    n = len(lst)
    wins = sum(1 for x in lst if x[4] > 0)
    sl = [x for x in lst if 'stop loss' in x[2].lower()]
    rugs = [x for x in lst if x[4] <= -10]  # ≤-10% close = rug-class
    sum_usd = sum(x[3] for x in lst)
    sum_sl = sum(x[3] for x in sl)
    print(f"\n### {label} (n={n})")
    print(f"  WR:           {100*wins/n:.1f}%  ({wins}/{n})")
    print(f"  Sum $:        {sum_usd:+.2f}")
    print(f"  Avg $/close:  {sum_usd/n:+.3f}")
    print(f"  SL hits:      {len(sl)} ({100*len(sl)/n:.0f}% of closes), sum ${sum_sl:+.2f}")
    print(f"  ≤ -10% rug-class events: {len(rugs)}  (worst: {min((x[4] for x in lst), default=0):+.2f}%)")

summarize("PRE-FILTER (7d window before enable)", pre)
summarize("POST-FILTER (since enable)", post)

print("\n## SMART-WALLET FILTER ACTIVITY")
sw_drops = 0
sw_tokens = {}
for f in sorted(Path('logs').glob('agent-2026-*.log')):
    for line in f.open(errors='ignore'):
        if 'Smart-wallet filter' in line:
            sw_drops += 1
            m = re.search(r'dropped ([^\s]+)', line)
            if m:
                sw_tokens[m.group(1)] = sw_tokens.get(m.group(1), 0) + 1
print(f"Total smart-wallet drops since enable: {sw_drops}")
print("Top 10 dropped tokens:")
for tok, n in sorted(sw_tokens.items(), key=lambda x: -x[1])[:10]:
    print(f"  {n:4d}  {tok}")

print("\n## CHRONIC LOSERS (eligible for auto-blacklist if rule were active)")
print("Pools with total_deploys >= 10 AND avg_pnl_pct < -0.3%:")
pm = json.load(open('pool-memory.json'))
chronic = [(v.get('name','?'), v.get('total_deploys', 0), v.get('avg_pnl_pct', 0))
           for v in pm.values()
           if v.get('total_deploys', 0) >= 10 and (v.get('avg_pnl_pct') or 0) < -0.3]
chronic.sort(key=lambda x: x[2])
for name, td, avg in chronic[:15]:
    print(f"  {name:24s} deploys={td:3d}  avg_pnl={avg:+.2f}%")

print("\n## URGENT SL fires per day (last 7 days)")
from collections import Counter
urgent_by_day = Counter()
for f in sorted(Path('logs').glob('agent-2026-*.log'))[-7:]:
    day = f.stem.replace('agent-', '')
    for line in f.open(errors='ignore'):
        if '[PnL poll] URGENT' in line:
            urgent_by_day[day] += 1
for day in sorted(urgent_by_day.keys()):
    print(f"  {day}: {urgent_by_day[day]}")
PYEOF

  echo ""
  echo "============================================================"
  echo "## RECOMMENDED REVIEW"
  echo "============================================================"
  cat <<'EOF'
Compare PRE-FILTER vs POST-FILTER summaries above:

1. If POST WR is similar (±5pp) and SL/rug counts dropped meaningfully:
   → Filters are working. Keep them. Consider adding chronic-loser auto-blacklist
     if any chronic-loser pools appeared above with avg_pnl < -0.3% AND
     deploys >= 10.

2. If POST WR dropped >10pp AND deploy count is starvation-level (<5/day):
   → Filters too strict. Consider loosening: drop requireSmartWallets first
     (keep minTokenAgeHours=6 alone).

3. If POST has another rug-class event (≤-10% close):
   → Smart-wallet filter alone isn't enough for rug prevention. Look at
     gmgn-source path again, or add unrenounced-mint / dev-team-hold filters
     on the meteora path.

4. If POST data is too sparse (<20 closes):
   → Wait another 2-3 days before judging. Re-run this script manually:
     bash /root/meridian/meridian/scripts/checkpoint_2026_05_29.sh
EOF
} > "$OUT" 2>&1

echo "Checkpoint report written: $OUT"

# Self-remove from crontab — leave the recurring 6h job intact
crontab -l 2>/dev/null | grep -v 'checkpoint_2026_05_29' | crontab -

echo "Crontab entry removed."
