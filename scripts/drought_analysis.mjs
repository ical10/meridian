// Deep drought analysis: raw universe per category, then a filter waterfall —
// add each knob one at a time and measure exactly what it costs.
const BASE = "https://pool-discovery-api.datapi.meteora.ag";

async function q(filters, category = "trending", timeframe = "30m", page_size = 50) {
  const url = `${BASE}/pools?page_size=${page_size}&filter_by=${encodeURIComponent(filters.join("&&"))}&timeframe=${timeframe}&category=${category}`;
  const res = await fetch(url);
  if (!res.ok) return { total: `HTTP ${res.status}`, data: [] };
  const j = await res.json();
  return { total: j.total, data: j.data || [] };
}

const BASELINE = ["pool_type=dlmm"];

console.log("══════════════════════════════════════════════════════");
console.log(" 1. RAW UNIVERSE BY CATEGORY (only pool_type=dlmm)");
console.log("══════════════════════════════════════════════════════");
for (const cat of ["trending", "new", "top", "graduated"]) {
  const r = await q(BASELINE, cat);
  console.log(`  category=${cat.padEnd(10)} → ${r.total} pools`);
}

console.log("");
console.log("══════════════════════════════════════════════════════");
console.log(" 2. FILTER WATERFALL (category=trending, 30m) — cumulative");
console.log("══════════════════════════════════════════════════════");
const steps = [
  ["pool_type=dlmm",                                     "dlmm only"],
  ["base_token_has_critical_warnings=false",             "no critical warnings"],
  ["quote_token_has_critical_warnings=false",            "quote no warnings"],
  ["base_token_has_high_single_ownership=false",         "no single-owner"],
  ["base_token_market_cap>=100000",                      "mcap >= 100k"],
  ["base_token_market_cap<=5000000",                     "mcap <= 5M"],
  ["base_token_holders>=500",                            "holders >= 500"],
  ["volume>=5000",                                       "volume >= 5k (30m)"],
  ["tvl>=10000",                                         "tvl >= 10k"],
  ["tvl<=150000",                                        "tvl <= 150k"],
  ["dlmm_bin_step>=80",                                  "bin_step >= 80"],
  ["dlmm_bin_step<=150",                                 "bin_step <= 150"],
  ["fee_active_tvl_ratio>=0.2",                          "fee/tvl >= 0.2"],
  ["base_token_organic_score>=60",                       "organic >= 60"],
  ["quote_token_organic_score>=60",                      "quote organic >= 60"],
  [`base_token_created_at<=${Date.now() - 12 * 3600_000}`, "age >= 12h"],
];
let acc = [];
let prev = null;
for (const [f, label] of steps) {
  acc.push(f);
  const r = await q(acc);
  const delta = prev == null ? "" : `  (-${prev - r.total})`;
  console.log(`  +${label.padEnd(24)} → ${String(r.total).padStart(4)}${delta}`);
  prev = typeof r.total === "number" ? r.total : prev;
}

console.log("");
console.log("══════════════════════════════════════════════════════");
console.log(" 3. SAME WATERFALL, category=new and top (final filter set)");
console.log("══════════════════════════════════════════════════════");
for (const cat of ["new", "top"]) {
  const r = await q(acc, cat);
  console.log(`  category=${cat.padEnd(10)} full filters → ${r.total} pools`);
}

console.log("");
console.log("══════════════════════════════════════════════════════");
console.log(" 4. WHAT EXISTS at mcap>=100k, dlmm, trending — show the pools");
console.log("    (only warnings+mcap filters, everything else open)");
console.log("══════════════════════════════════════════════════════");
const loose = await q([
  "pool_type=dlmm",
  "base_token_has_critical_warnings=false",
  "base_token_market_cap>=100000",
  "base_token_market_cap<=5000000",
], "trending");
console.log(`  total: ${loose.total}`);
for (const p of loose.data.slice(0, 15)) {
  const vol = p.volume ?? p.volume_30m ?? "?";
  const binStep = p.dlmm_params?.bin_step ?? "?";
  console.log(`  ${String(p.pool_name || p.name || "?").padEnd(20)} tvl=$${Math.round(p.tvl ?? 0).toString().padEnd(8)} vol30m=$${String(Math.round(Number(vol) || 0)).padEnd(8)} feeTvl=${String(p.fee_active_tvl_ratio ?? "?").slice(0,6).padEnd(7)} binStep=${String(binStep).padEnd(4)} organic=${p.base_token_organic_score ?? "?"} holders=${p.base_token_holders ?? "?"} mcap=$${Math.round((p.base_token_market_cap ?? 0)/1000)}k`);
}

console.log("");
console.log("══════════════════════════════════════════════════════");
console.log(" 5. MARKET-WIDE: total dlmm universe across timeframes");
console.log("══════════════════════════════════════════════════════");
for (const tf of ["30m", "1h", "24h"]) {
  const r = await q(["pool_type=dlmm", "volume>=5000"], "trending", tf);
  console.log(`  dlmm + vol>=5k @ ${tf.padEnd(4)} → ${r.total} pools`);
}
