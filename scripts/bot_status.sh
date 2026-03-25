#!/bin/bash
# Verify the Meridian bot: process, live config values, and recent activity.
# Usage: ./scripts/bot_status.sh
# Read-only — makes no changes. Run kill_stale_bots.sh separately to clean duplicates.

cd /root/meridian/meridian

# Canonical bot processes: `node .../index.js`, excluding bash wrappers, pgrep, and
# transient `node -e import(...)` module-load tests.
mapfile -t BOT_PIDS < <(pgrep -f "index\.js" | while read -r pid; do
  # only real node binaries — never bash wrappers whose cmdline merely mentions index.js
  exe=$(basename "$(readlink "/proc/$pid/exe" 2>/dev/null)" 2>/dev/null)
  [ "$exe" = "node" ] || continue
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  case "$cmd" in
    *openclaw*) continue ;;                                         # unrelated gateway
    *"--input-type=module"*|*"-e "*|*"import("*) continue ;;        # skip module-load tests
    *"node "*"index.js"*) echo "$pid" ;;
  esac
done)

echo "=== PROCESS ==="
if [ "${#BOT_PIDS[@]}" -eq 0 ]; then
  echo "  NOT RUNNING — no canonical index.js process found"
elif [ "${#BOT_PIDS[@]}" -eq 1 ]; then
  echo "  OK — single instance, PID ${BOT_PIDS[0]}"
else
  echo "  WARNING — ${#BOT_PIDS[@]} instances running (duplicates): ${BOT_PIDS[*]}"
  echo "  Run ./scripts/kill_stale_bots.sh to clean up"
fi
echo ""

echo "=== LIVE CONFIG ==="
node -e "import('./config.js').then(m=>{
  const s=m.config.screening, mg=m.config.management, llm=m.config.llm;
  const rows={
    stopLossPct: mg.stopLossPct,
    takeProfitPct: mg.takeProfitPct,
    trailingTriggerPct: mg.trailingTriggerPct,
    trailingDropPct: mg.trailingDropPct,
    outOfRangeWaitMinutes: mg.outOfRangeWaitMinutes,
    minVolatility: s.minVolatility,
    maxVolatility: s.maxVolatility,
    'feeActiveTvlBands': JSON.stringify(s.feeActiveTvlBands),
    'recentLossCooldownTiers': JSON.stringify(mg.recentLossCooldownTiers),
    minTvl: s.minTvl, maxTvl: s.maxTvl, minVolume: s.minVolume, minMcap: s.minMcap,
    deployAmountSol: mg.deployAmountSol, maxPositions: m.config.risk?.maxPositions ?? mg.maxPositions,
    model: llm.screeningModel,
  };
  for (const [k,v] of Object.entries(rows)) console.log('  '+k+': '+(v??'(unset)'));
}).catch(e=>{console.error('  CONFIG LOAD FAILED:', e.message); process.exit(1);})"
echo ""

echo "=== RECENT ACTIVITY (last 12 log lines) ==="
LOG="logs/agent-$(date -u +%Y-%m-%d).log"
if [ -f "$LOG" ]; then
  tail -12 "$LOG" | sed 's/^/  /'
else
  echo "  No log file for today ($LOG)"
fi
echo ""

echo "=== OPEN POSITIONS (state.json) ==="
python3 -c "
import json
try:
    s = json.load(open('state.json'))
    opens = [(k,p) for k,p in s['positions'].items() if not p.get('closed_at')]
    print(f'  open: {len(opens)}')
    for k,p in opens:
        print(f\"    {p.get('pool_name')} peak={p.get('peak_pnl_pct')}% oor_since={p.get('out_of_range_since')} deployed={p.get('deployed_at','')[:19]}\")
except Exception as e:
    print(f'  state.json read failed: {e}')
"
