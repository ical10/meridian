// Cumulative probe: add filters one at a time to find where the universe collapses.
// Read-only. Usage: node scripts/filter_probe2.mjs
import { config } from "../config.js";

const BASE = "https://pool-discovery-api.datapi.meteora.ag";
const s = config.screening;

const FILTERS = [
  ["pool_type=dlmm", "pool_type=dlmm"],
  [`minTvl ${s.minTvl}`, `tvl>=${s.minTvl}`],
  [`maxTvl ${s.maxTvl}`, `tvl<=${s.maxTvl}`],
  [`minVolume ${s.minVolume}`, `volume>=${s.minVolume}`],
  [`minMcap ${s.minMcap}`, `base_token_market_cap>=${s.minMcap}`],
  [`maxMcap ${s.maxMcap}`, `base_token_market_cap<=${s.maxMcap}`],
  [`minHolders ${s.minHolders}`, `base_token_holders>=${s.minHolders}`],
  [`minBinStep ${s.minBinStep}`, `dlmm_bin_step>=${s.minBinStep}`],
  [`maxBinStep ${s.maxBinStep}`, `dlmm_bin_step<=${s.maxBinStep}`],
  [`feeActiveTvl>=0.2`, `fee_active_tvl_ratio>=0.2`],
  [`minOrganic ${s.minOrganic}`, `base_token_organic_score>=${s.minOrganic}`],
  [`minQuoteOrganic ${s.minQuoteOrganic}`, `quote_token_organic_score>=${s.minQuoteOrganic}`],
  [`minTokenAgeHours ${s.minTokenAgeHours}`, `base_token_created_at<=${Date.now() - s.minTokenAgeHours * 3_600_000}`],
  ["no critical warnings", "base_token_has_critical_warnings=false&&quote_token_has_critical_warnings=false"],
  ["no high single ownership", "base_token_has_high_single_ownership=false"],
];

async function countWith(filterTerms) {
  const url = `${BASE}/pools?page_size=1&filter_by=${encodeURIComponent(filterTerms.join("&&"))}` +
    `&timeframe=${s.timeframe}&category=${s.category}`;
  const res = await fetch(url);
  if (!res.ok) return `HTTP ${res.status}`;
  const data = await res.json();
  return data.total ?? "?";
}

const acc = [];
for (const [label, f] of FILTERS) {
  acc.push(f);
  console.log(`+ ${label.padEnd(28)} -> ${await countWith(acc)}`);
}
