#!/bin/bash
# One-shot candidate-drought monitor. Run via `at` ~8h after setup.
# Reports: screening cycles, candidates seen, LLM verdicts, deploys in the window.
# If no candidates/deploys: runs the funnel diagnostic to identify the blocking knob.
# Output: checkpoints/candidates_8h.log + Telegram summary.

cd /root/meridian/meridian
mkdir -p checkpoints

OUT="checkpoints/candidates_8h.log"
WINDOW_START="${WINDOW_START:-$(date -u -d '8 hours ago' +%Y-%m-%dT%H:%M)}"
TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2 | awk '{print $1}')
TG_CHAT=$(python3 -c "import json; print(json.load(open('user-config.json'))['telegramChatId'])")

{
  echo "═══════════════════════════════════════════════════════════════"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] CANDIDATE MONITOR — window since $WINDOW_START"
  echo "═══════════════════════════════════════════════════════════════"

  python3 - <<PY
import re
from pathlib import Path
from datetime import datetime

win = "$WINDOW_START"

def lines_since(win_str):
    out = []
    ts_re = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})")
    for f in sorted(Path("logs").glob("agent-2026-*.log"))[-2:]:  # today + yesterday
        for line in f.read_text(errors="ignore").splitlines():
            m = ts_re.match(line)
            if m and m.group(1) >= win_str:
                out.append(line)
    return out

L = lines_since(win)

cycles      = [l for l in L if "Starting screening cycle" in l]
skipped_max = [l for l in L if "max positions reached" in l]
skipped_cd  = [l for l in L if "Screening short-circuit" in l]
deploys     = [l for l in L if "[DEPLOY] Pool:" in l]
llm_evals   = [l for l in L if "Final answer reached" in l]
rejected    = [l for l in L if "REJECTED" in l]
no_cand     = [l for l in L if "No candidates" in l or "0 candidates" in l]
filtered    = [l for l in L if "[SCREENING] Filtered" in l]

print(f"screening cycles run:     {len(cycles)}")
print(f"skipped (max positions):  {len(skipped_max)}")
print(f"skipped (short-circuit):  {len(skipped_cd)}")
print(f"LLM evaluations:          {len(llm_evals)}")
print(f"DEPLOYS:                  {len(deploys)}")
print(f"explicit REJECTED:        {len(rejected)}")
print(f"cycles w/ no candidates:  {len(no_cand)}")
print(f"hard-filter drops logged: {len(filtered)}")
print()
if deploys:
    print("--- DEPLOYS ---")
    for l in deploys: print(" ", l[:120])
    print()
if rejected:
    print("--- LLM REJECTION SAMPLES (last 5) ---")
    for l in rejected[-5:]: print(" ", l[:160])
    print()
if filtered:
    from collections import Counter
    reasons = Counter()
    for l in filtered:
        m = re.search(r"Filtered (?:cooldown )?\S+.*?[—-] (.*)$", l)
        reasons[(m.group(1)[:50] if m else "cooldown/other")] += 1
    print("--- HARD-FILTER DROP REASONS ---")
    for r, n in reasons.most_common(8): print(f"  {n}x {r}")
    print()

# verdict
if len(deploys) > 0:
    print("VERDICT: deploys happened — drought over.")
elif len(llm_evals) > 0:
    print("VERDICT: candidates reached the LLM but none deployed — LLM holding the bounce-thesis line (see rejection samples; if reasons look wrong, loosen thesis prompt or filters).")
else:
    print("VERDICT: NO candidates reached the LLM in the window — funnel diagnostic below shows the blocking knob.")
PY

  # If nothing reached the LLM, capture the live funnel state
  if ! grep -qE "DEPLOYS:\s+[1-9]" "$OUT" 2>/dev/null; then
    echo ""
    echo "--- LIVE FUNNEL DIAGNOSTIC ---"
    timeout 90 node scripts/screen_funnel.mjs 2>&1
  fi

  echo "[done: $(date -u +%H:%M:%SZ)]"
} >> "$OUT" 2>&1

# Telegram summary
SUMMARY=$(python3 - <<'PY'
lines = open("checkpoints/candidates_8h.log").read().splitlines()
# take from the last header onward
idx = max(i for i, l in enumerate(lines) if "CANDIDATE MONITOR" in l)
block = lines[idx:]
keep = [l for l in block if any(k in l for k in
    ["screening cycles","DEPLOYS:","LLM rejections","no candidates","VERDICT","skipped"])]
print("🔎 8h candidate monitor\n" + "\n".join(keep[:12]) + "\n\nFull log: checkpoints/candidates_8h.log")
PY
)
if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=${SUMMARY}" > /dev/null 2>&1 || true
fi

# One-shot: remove self from crontab after running (skip during smoke tests)
if [ "${KEEP_CRON:-0}" != "1" ]; then
  crontab -l 2>/dev/null | grep -v 'monitor_candidates_8h' | crontab - 2>/dev/null || true
fi
