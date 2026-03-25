// Leave-one-out probe of pool-discovery API filters: which knob is choking the universe?
// Read-only. Usage: node scripts/filter_probe.mjs
import { config } from "../config.js";

const BASE = "https://pool-discovery-api.datapi.meteora.ag";
const s = config.screening;

const FILTERS = [
  ["critical warnings (base)", "base_token_has_critical_warnings=false"],
  ["critical warnings (quote)", "quote_token_has_critical_warnings=false"],
  ["high single ownership", "base_token_has_high_single_ownership=false"],
  ["pool_type=dlmm", "pool_type=dlmm"],
  [`minMcap ${s.minMcap}`, `base_token_market_cap>=${s.minMcap}`],
  [`maxMcap ${s.maxMcap}`, `base_token_market_cap<=${s.maxMcap}`],
  [`minHolders ${s.minHolders}`, `base_token_holders>=${s.minHolders}`],
  [`minVolume ${s.minVolume}`, `volume>=${s.minVolume}`],
  [`minTvl ${s.minTvl}`, `tvl>=${s.minTvl}`],
  [`maxTvl ${s.maxTvl}`, `tvl<=${s.maxTvl}`],
  [`minBinStep ${s.minBinStep}`, `dlmm_bin_step>=${s.minBinStep}`],
  [`maxBinStep ${s.maxBinStep}`, `dlmm_bin_step<=${s.maxBinStep}`],
  [`feeActiveTvl>=0.2`, `fee_active_tvl_ratio>=0.2`],
  [`minOrganic ${s.minOrganic}`, `base_token_organic_score>=${s.minOrganic}`],
  [`minQuoteOrganic ${s.minQuoteOrganic}`, `quote_token_organic_score>=${s.minQuoteOrganic}`],
  [`minTokenAgeHours ${s.minTokenAgeHours}`, `base_token_created_at<=${Date.now() - s.minTokenAgeHours * 3_600_000}`],
];

async function countWith(filterTerms) {
  const url = `${BASE}/pools?page_size=1&filter_by=${encodeURIComponent(filterTerms.join("&&"))}` +
    `&timeframe=${s.timeframe}&category=${s.category}`;
  const res = await fetch(url);
  if (!res.ok) return `HTTP ${res.status}`;
  const data = await res.json();
  return data.total ?? "?";
}

const all = FILTERS.map(([, f]) => f);
console.log(`ALL filters (baseline): ${await countWith(all)} pools  [category=${s.category} timeframe=${s.timeframe}]`);
console.log(`NO filters at all     : ${await countWith(["pool_type=dlmm"])} pools\n`);
console.log("Leave-one-out (universe size if this single filter were removed):");
for (let i = 0; i < FILTERS.length; i++) {
  const subset = all.filter((_, j) => j !== i);
  const total = await countWith(subset);
  console.log(`  drop ${FILTERS[i][0].padEnd(28)} -> ${total}`);
}
