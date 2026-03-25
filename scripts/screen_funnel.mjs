// One-shot screening funnel: how many pools survive each filter stage, and why the rest die.
// Read-only. Usage: node scripts/screen_funnel.mjs
import { config } from "../config.js";
import { discoverPools } from "../tools/screening.js";

const s = config.screening;
console.log("=== ACTIVE SCREENING KNOBS ===");
for (const k of ["category","timeframe","minTvl","maxTvl","minVolume","minMcap","maxMcap",
  "minFeeActiveTvlRatio","maxFeeActiveTvlRatio","feeActiveTvlBands","minVolatility","maxVolatility",
  "minBinStep","maxBinStep","minTokenAgeHours","minTokenFeesSol","minOrganic","minHolders",
  "athFilterPct","maxPriceChangePct","maxHourlyDumpPct","maxBundlePct","maxTop10Pct"]) {
  console.log(`  ${k}: ${JSON.stringify(s[k])}`);
}
console.log("");

// discoverPools applies the API-level/coarse filters (category, volume, mcap, age, bands,
// volatility floor/ceiling, bin step, organic, holders, blacklist). Whatever survives is `pools`.
const disc = await discoverPools({ page_size: 50 });
console.log("=== DISCOVERY STAGE (coarse / API filters) ===");
console.log(`  raw pool universe (data.total): ${disc.total}`);
console.log(`  survived discovery filters:     ${disc.pools.length}`);
console.log("");

// Aggregate rejection reasons from discovery
const reasonBuckets = {};
for (const e of (disc.filtered_examples || [])) {
  // normalize reason to a category prefix
  const r = (e.reason || "").replace(/\$?-?\d[\d.,]*/g, "N").slice(0, 40);
  reasonBuckets[r] = (reasonBuckets[r] || 0) + 1;
}
console.log("=== DISCOVERY REJECTION REASONS (sampled) ===");
const sorted = Object.entries(reasonBuckets).sort((a,b)=>b[1]-a[1]);
if (sorted.length === 0) console.log("  (none sampled — discovery returned its survivors)");
for (const [r,n] of sorted) console.log(`  ${n}x  ${r}`);
console.log("");

// Now apply the fine filters from getTopCandidates manually, counting drop-off per knob.
const pools = disc.pools;
const stages = [
  ["minTvl",        p => { const t=Number(p.tvl??p.active_tvl??0); return !(s.minTvl>0 && t<s.minTvl); }],
  ["maxTvl",        p => { const t=Number(p.tvl??p.active_tvl??0); return !(s.maxTvl>0 && t>s.maxTvl); }],
  ["minFeeActiveTvl", p => { const f=Number(p.fee_active_tvl_ratio); return !(s.minFeeActiveTvlRatio>0 && (!Number.isFinite(f)||f<s.minFeeActiveTvlRatio)); }],
  ["usableVolatility", p => Number.isFinite(Number(p.volatility)) && Number(p.volatility) > 0],
  ["maxVolatility", p => { const v=Number(p.volatility); return !(s.maxVolatility!=null && Number.isFinite(v) && v>s.maxVolatility); }],
  ["maxPriceChange±", p => { const c=p.pool_price_change_pct; return !(s.maxPriceChangePct!=null && Number.isFinite(c) && Math.abs(c)>s.maxPriceChangePct); }],
];

console.log("=== FINE-FILTER FUNNEL (post-discovery) ===");
let survivors = pools.slice();
console.log(`  start (discovery survivors): ${survivors.length}`);
for (const [name, fn] of stages) {
  const before = survivors.length;
  const killed = survivors.filter(p => !fn(p));
  survivors = survivors.filter(fn);
  const note = killed.length && killed.length <= 6
    ? "  [" + killed.map(p => `${p.name || p.base?.symbol}:${name==="maxPriceChange±"?(p.pool_price_change_pct):(name.includes("Volatility")?p.volatility:name.includes("Fee")?p.fee_active_tvl_ratio:Math.round(Number(p.tvl??p.active_tvl??0)))}`).join(", ") + "]"
    : "";
  console.log(`  after ${name.padEnd(18)}: ${survivors.length}  (-${before-survivors.length})${note}`);
}
console.log("");
console.log("=== SURVIVORS (would go to LLM) ===");
if (survivors.length === 0) console.log("  NONE");
for (const p of survivors.slice(0, 10)) {
  console.log(`  ${p.name || p.base?.symbol}: tvl=$${Math.round(Number(p.tvl??p.active_tvl??0))} fee/tvl=${p.fee_active_tvl_ratio} vol=${p.volatility} 1h=${p.pool_price_change_pct}% mcap=$${p.base?.mcap ?? "?"}`);
}
