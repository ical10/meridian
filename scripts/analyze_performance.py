#!/usr/bin/env python3
"""Meridian performance analyzer — joins state.json with logs/agent-*.log
to produce per-close records, then reports the metrics from the
@dikibagast tweet's tip #2: peak PnL distribution, peak→close giveback,
drawdown→recovery, exit-reason mix, and win-rate cuts by dimension.

Pure stdlib. Run from anywhere:

  python3 scripts/analyze_performance.py
  python3 scripts/analyze_performance.py --since 2026-05-01
  python3 scripts/analyze_performance.py --since 2026-05-10 --details
"""

import argparse
import json
import re
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATE_PATH = ROOT / "state.json"
LOGS_DIR = ROOT / "logs"

CLOSE_RE = re.compile(
    r"\[([^\]]+)\] \[CLOSE\] Closed PnL from API: pnl=(-?\d+\.\d+) USD "
    r"\((-?\d+\.\d+)%\), withdrawn=(\d+\.\d+), deposited=(\d+\.\d+)"
)
MARKED_CLOSED_RE = re.compile(
    r"\[([^\]]+)\] \[STATE\] Position (\w+) marked closed: (.+)$"
)
PEAK_RE = re.compile(
    r"\[([^\]]+)\] \[STATE\] Position (\w+) peak PnL accepted at "
    r"(-?\d+\.?\d*)% from relay poll"
)
EXIT_SL_RE = re.compile(
    r"\[([^\]]+)\] \[STATE\] Exit alert for ([^:]+): Stop loss: PnL "
    r"(-?\d+\.\d+)% <= (-?\d+)%"
)


def parse_iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def iter_log_files(since=None):
    for f in sorted(LOGS_DIR.glob("agent-*.log")):
        if since:
            try:
                d = datetime.strptime(f.stem.replace("agent-", ""), "%Y-%m-%d").date()
                if d < since:
                    continue
            except ValueError:
                pass
        yield f


def scan_logs(since=None):
    closes_by_addr = {}
    peaks_by_addr = defaultdict(list)
    sl_alerts_by_pair = defaultdict(list)

    for f in iter_log_files(since):
        # Pending "marked closed" events awaiting their [CLOSE] companion (within 60s)
        pending = []
        with f.open(errors="ignore") as fh:
            for line in fh:
                if "marked closed:" in line:
                    m = MARKED_CLOSED_RE.search(line)
                    if m:
                        pending.append((parse_iso(m.group(1)), m.group(2), m.group(3).strip()))
                    continue
                if "[CLOSE] Closed PnL" in line:
                    m = CLOSE_RE.search(line)
                    if m:
                        ts = parse_iso(m.group(1))
                        for i, (pts, addr, reason) in enumerate(pending):
                            if abs((ts - pts).total_seconds()) <= 60:
                                closes_by_addr[addr] = {
                                    "close_ts": ts,
                                    "pnl_usd": float(m.group(2)),
                                    "pnl_pct": float(m.group(3)),
                                    "reason": reason,
                                }
                                pending.pop(i)
                                break
                    continue
                if "peak PnL accepted" in line:
                    m = PEAK_RE.search(line)
                    if m:
                        peaks_by_addr[m.group(2)].append((parse_iso(m.group(1)), float(m.group(3))))
                    continue
                if "Exit alert" in line and "Stop loss" in line:
                    m = EXIT_SL_RE.search(line)
                    if m:
                        sl_alerts_by_pair[m.group(2).strip()].append(
                            (parse_iso(m.group(1)), float(m.group(3)))
                        )

    return closes_by_addr, peaks_by_addr, sl_alerts_by_pair


def build_records(since=None):
    state = json.load(STATE_PATH.open())
    closes, peaks, sl_alerts = scan_logs(since)
    records = []
    for addr, p in state["positions"].items():
        if not p.get("closed"):
            continue
        deployed_at = parse_iso(p["deployed_at"]) if p.get("deployed_at") else None
        closed_at = parse_iso(p["closed_at"]) if p.get("closed_at") else None
        if since and closed_at and closed_at.date() < since:
            continue

        close = closes.get(addr)
        pair = p.get("pool_name") or ""
        sl_during = [
            (ts, pnl) for ts, pnl in sl_alerts.get(pair, [])
            if deployed_at and closed_at and deployed_at <= ts <= closed_at
        ]
        peak_track = peaks.get(addr, [])

        records.append({
            "addr": addr,
            "pool": pair,
            "strategy": p.get("strategy"),
            "bin_step": p.get("bin_step"),
            "bins_below": (p.get("bin_range") or {}).get("bins_below"),
            "amount_sol": p.get("amount_sol"),
            "volatility": p.get("volatility"),
            "organic_score": p.get("organic_score"),
            "deployed_at": deployed_at,
            "closed_at": closed_at,
            "hold_min": (closed_at - deployed_at).total_seconds() / 60 if deployed_at and closed_at else None,
            "peak_pnl_pct": p.get("peak_pnl_pct") or 0,
            "peak_samples": len(peak_track),
            "close_pnl_pct": close["pnl_pct"] if close else None,
            "close_pnl_usd": close["pnl_usd"] if close else None,
            "close_reason": close["reason"] if close else None,
            "min_observed_pnl": min((p for _, p in sl_during), default=None),
            "sl_alert_count": len(sl_during),
            "fees_claimed_usd": p.get("total_fees_claimed_usd") or 0,
        })
    return records


def stats(vals):
    vals = sorted(v for v in vals if v is not None)
    if not vals:
        return None
    n = len(vals)
    q = lambda p: vals[max(0, min(n - 1, int(p * n)))]
    return dict(n=n, min=vals[0], p10=q(0.1), p25=q(0.25), median=q(0.5),
                p75=q(0.75), p90=q(0.9), max=vals[-1], mean=sum(vals) / n)


def fmt_stats(s, unit=""):
    if not s:
        return "no data"
    u = unit
    return (f"n={s['n']:>4d}  min={s['min']:+6.2f}{u}  p10={s['p10']:+6.2f}  "
            f"p25={s['p25']:+6.2f}  med={s['median']:+6.2f}  p75={s['p75']:+6.2f}  "
            f"p90={s['p90']:+6.2f}  max={s['max']:+6.2f}  |  mean={s['mean']:+6.2f}{u}")


def pct(x, n):
    return f"{100*x/n:5.1f}%" if n else "    —"


def simplify_reason(reason):
    r = (reason or "").lower()
    if "stop loss" in r:        return "Stop loss"
    if "trailing tp" in r:      return "Trailing TP"
    if "out of range" in r:     return "OOR"
    if "take profit" in r or "rule 2" in r:    return "Take profit (rule 2)"
    if "pumped" in r or "rule 3" in r:         return "Pumped above range"
    if "low yield" in r or "rule 5" in r:      return "Low yield"
    if "instruction" in r:      return "Instruction"
    if "manual" in r:           return "Manual"
    return (reason or "unknown")[:36]


def section(title):
    print(f"\n## {title}")


def report_headline(records):
    section("HEADLINE")
    closed = [r for r in records if r["close_pnl_pct"] is not None]
    n = len(closed)
    if not n:
        print("  no closed records joined to a [CLOSE] log line"); return
    wins = [r for r in closed if r["close_pnl_pct"] > 0]
    losses = [r for r in closed if r["close_pnl_pct"] <= 0]
    total_usd = sum(r["close_pnl_usd"] for r in closed)
    print(f"  closed (joined to logs): {n}")
    print(f"  wins: {len(wins)} ({pct(len(wins), n)})   losses: {len(losses)} ({pct(len(losses), n)})")
    print(f"  total realized USD: ${total_usd:+.2f}   avg per close: ${total_usd/n:+.3f}")
    if wins:
        avg_w = sum(r["close_pnl_usd"] for r in wins) / len(wins)
        print(f"  avg win: ${avg_w:+.2f}   median win %: {sorted(r['close_pnl_pct'] for r in wins)[len(wins)//2]:+.2f}%")
    if losses:
        avg_l = sum(r["close_pnl_usd"] for r in losses) / len(losses)
        print(f"  avg loss: ${avg_l:+.2f}   median loss %: {sorted(r['close_pnl_pct'] for r in losses)[len(losses)//2]:+.2f}%")


def report_peak(records):
    section("PEAK PnL DISTRIBUTION (state.json peak_pnl_pct)")
    peaks = [r["peak_pnl_pct"] for r in records]
    print(f"  {fmt_stats(stats(peaks), '%')}")
    buckets = [("(-∞,0)", lambda x: x < 0),
               ("[0,1)",  lambda x: 0 <= x < 1),
               ("[1,3)",  lambda x: 1 <= x < 3),
               ("[3,5)",  lambda x: 3 <= x < 5),
               ("[5,10)", lambda x: 5 <= x < 10),
               ("[10,20)", lambda x: 10 <= x < 20),
               ("[20,∞)", lambda x: x >= 20)]
    print("  bucket → count (share)")
    for label, pred in buckets:
        c = sum(1 for v in peaks if pred(v))
        print(f"    {label:8s}  {c:4d}  ({pct(c, len(peaks))})")


def report_giveback(records):
    section("PEAK → CLOSE GIVEBACK (peak - close pnl_pct)")
    closed = [r for r in records if r["close_pnl_pct"] is not None]
    gb_all = [r["peak_pnl_pct"] - r["close_pnl_pct"] for r in closed]
    print(f"  all closes:                {fmt_stats(stats(gb_all), '%')}")
    armed = [r for r in closed if r["peak_pnl_pct"] >= 2.5]
    if armed:
        gb_a = [r["peak_pnl_pct"] - r["close_pnl_pct"] for r in armed]
        print(f"  trailing-armed (peak≥2.5): {fmt_stats(stats(gb_a), '%')}")
    big = [r for r in closed if r["peak_pnl_pct"] >= 10]
    if big:
        gb_b = [r["peak_pnl_pct"] - r["close_pnl_pct"] for r in big]
        print(f"  big winners (peak≥10):     {fmt_stats(stats(gb_b), '%')}")
    print()
    print("  → on average, every winner gives back this much from its peak.")
    print("    raise trailingDropPct only if mean giveback < trailingDropPct currently set.")


def report_exits(records):
    section("EXIT REASON MIX")
    counter = Counter()
    pnl_by = defaultdict(list)
    for r in records:
        if not r["close_reason"]:
            continue
        reason = simplify_reason(r["close_reason"])
        counter[reason] += 1
        if r["close_pnl_pct"] is not None:
            pnl_by[reason].append(r["close_pnl_pct"])
    n = sum(counter.values())
    print(f"  {'reason':36s} {'n':>5s} {'share':>7s} {'avg pnl%':>10s} {'WR':>6s}")
    for reason, cnt in counter.most_common():
        vals = pnl_by[reason]
        avg = sum(vals) / len(vals) if vals else 0
        wr = sum(1 for v in vals if v > 0) / max(1, len(vals)) * 100
        print(f"  {reason:36s} {cnt:5d} {pct(cnt, n):>7s} {avg:+9.2f}% {wr:5.1f}%")


def report_recovery(records):
    section("DRAWDOWN → RECOVERY  (tip 2: \"the clue is recovery\")")
    print("  Positions whose Stop-loss alert fired at least once while open")
    print("  (i.e. PnL dipped to/past the configured SL threshold).")
    print("  Outcome: did the position end positive (recovered) or negative?\n")
    with_dd = [r for r in records if r["min_observed_pnl"] is not None]
    if not with_dd:
        print("  no SL-alert events in this window — log range may be too narrow"); return
    n = len(with_dd)
    recovered = [r for r in with_dd if (r["close_pnl_pct"] or 0) > 0]
    stayed_neg = [r for r in with_dd if (r["close_pnl_pct"] or 0) <= 0]
    print(f"  positions with ≥1 SL alert during open:  {n}")
    print(f"    closed positive (recovered):           {len(recovered):4d}  ({pct(len(recovered), n)})")
    print(f"    closed negative (stayed down):         {len(stayed_neg):4d}  ({pct(len(stayed_neg), n)})")
    if recovered:
        avg_min = sum(r["min_observed_pnl"] for r in recovered) / len(recovered)
        avg_close = sum(r["close_pnl_pct"] for r in recovered) / len(recovered)
        avg_usd = sum(r["close_pnl_usd"] for r in recovered) / len(recovered)
        total_usd = sum(r["close_pnl_usd"] for r in recovered)
        print(f"\n  recovered positions:")
        print(f"    avg min PnL observed: {avg_min:+.2f}%   avg close PnL: {avg_close:+.2f}%")
        print(f"    avg realized USD: ${avg_usd:+.2f}   total: ${total_usd:+.2f}")
        print(f"    → a strict SL would have cut these as losses; allowing recovery captured ${total_usd:+.2f}")
    if stayed_neg:
        avg_close = sum(r["close_pnl_pct"] for r in stayed_neg) / len(stayed_neg)
        avg_usd = sum(r["close_pnl_usd"] for r in stayed_neg) / len(stayed_neg)
        total_usd = sum(r["close_pnl_usd"] for r in stayed_neg)
        print(f"\n  stayed-negative positions:")
        print(f"    avg close PnL: {avg_close:+.2f}%   avg realized USD: ${avg_usd:+.2f}   total: ${total_usd:+.2f}")
        print(f"    → these would have closed earlier under a strict SL — would have limited loss to threshold.")


def report_dimensions(records):
    section("WIN RATE BY DIMENSION")
    closed = [r for r in records if r["close_pnl_pct"] is not None]

    def cut(name, key_fn, label_fn=str):
        groups = defaultdict(list)
        for r in closed:
            k = key_fn(r)
            if k is None:
                continue
            groups[k].append(r)
        if not groups:
            return
        print(f"\n  {name}")
        print(f"    {'bucket':12s} {'n':>5s} {'WR':>6s} {'avg pnl%':>10s} {'avg $':>8s} {'sum $':>10s}")
        for k in sorted(groups.keys(), key=lambda x: (isinstance(x, str), x)):
            recs = groups[k]
            wins = sum(1 for r in recs if r["close_pnl_pct"] > 0)
            avg_pct = sum(r["close_pnl_pct"] for r in recs) / len(recs)
            avg_usd = sum(r["close_pnl_usd"] for r in recs) / len(recs)
            sum_usd = sum(r["close_pnl_usd"] for r in recs)
            print(f"    {label_fn(k):12s} {len(recs):5d} {pct(wins, len(recs)):>6s} "
                  f"{avg_pct:+9.2f}% {avg_usd:+7.3f} {sum_usd:+9.2f}")

    cut("bin_step", lambda r: r["bin_step"])
    cut("strategy", lambda r: r["strategy"])

    def vol_bucket(r):
        v = r["volatility"]
        if v is None: return None
        if v < 2: return "<2"
        if v < 4: return "2-4"
        if v < 6: return "4-6"
        return "6+"
    cut("volatility", vol_bucket)

    def hold_bucket(r):
        h = r["hold_min"]
        if h is None: return None
        if h < 15:  return "<15m"
        if h < 60:  return "15-60m"
        if h < 180: return "60-180m"
        if h < 720: return "3-12h"
        return "12h+"
    cut("hold time", hold_bucket)

    def peak_bucket(r):
        p = r["peak_pnl_pct"]
        if p is None: return None
        if p < 0:  return "neg"
        if p < 1:  return "[0,1)"
        if p < 3:  return "[1,3)"
        if p < 5:  return "[3,5)"
        if p < 10: return "[5,10)"
        return "10+"
    cut("peak_pnl_pct", peak_bucket)


def report_details(records, limit=40):
    section(f"PER-POSITION DETAIL (last {limit} by close time)")
    closed = sorted(
        [r for r in records if r["closed_at"]],
        key=lambda r: r["closed_at"],
        reverse=True,
    )[:limit]
    print(f"  {'closed_at':20s} {'pool':22s} {'hold':>6s} "
          f"{'bs':>3s} {'peak%':>7s} {'close%':>7s} {'$pnl':>7s}  reason")
    for r in closed:
        ts = r["closed_at"].strftime("%Y-%m-%d %H:%M")
        hold = f"{r['hold_min']:.0f}m" if r["hold_min"] is not None else "?"
        peak = f"{r['peak_pnl_pct']:+.2f}" if r["peak_pnl_pct"] is not None else "?"
        close_pct = f"{r['close_pnl_pct']:+.2f}" if r["close_pnl_pct"] is not None else "?"
        close_usd = f"{r['close_pnl_usd']:+.2f}" if r["close_pnl_usd"] is not None else "?"
        bs = str(r["bin_step"] or "?")
        reason = simplify_reason(r["close_reason"])
        print(f"  {ts:20s} {(r['pool'] or '?')[:22]:22s} {hold:>6s} "
              f"{bs:>3s} {peak:>7s} {close_pct:>7s} {close_usd:>7s}  {reason}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--since", help="YYYY-MM-DD, restrict closes & log scan from this date")
    ap.add_argument("--details", action="store_true", help="Print per-position recent table")
    args = ap.parse_args()
    since = datetime.strptime(args.since, "%Y-%m-%d").date() if args.since else None

    print(f"# Meridian Performance Analyzer  ({STATE_PATH.parent})")
    print(f"# since: {since or 'all-time'}")
    records = build_records(since)
    print(f"# {len(records)} closed positions loaded")
    joined = sum(1 for r in records if r["close_pnl_pct"] is not None)
    print(f"# {joined} joined to [CLOSE] log line  "
          f"({100*joined/len(records):.0f}% — older closes lack log coverage)")

    report_headline(records)
    report_peak(records)
    report_giveback(records)
    report_exits(records)
    report_recovery(records)
    report_dimensions(records)
    if args.details:
        report_details(records)


if __name__ == "__main__":
    main()
