// Probe PROPOSED loosened filters: what universe do we get, and what binds next?
// Read-only. Usage: node scripts/filter_probe3.mjs
const BASE = "https://pool-discovery-api.datapi.meteora.ag";

// proposed values
const P = { minTvl: 10000, maxTvl: 250000, minVolume: 2000, minMcap: 100000, maxMcap: 10000000,
  minHolders: 500, minBinStep: 80, maxBinStep: 150, feeTvl: 0.2, minOrganic: 60, minQuoteOrganic: 60,
  minTokenAgeHours: 12 };

function filters(p) {
  return [
    "pool_type=dlmm",
    `tvl>=${p.minTvl}`, `tvl<=${p.maxTvl}`,
    `volume>=${p.minVolume}`,
    `base_token_market_cap>=${p.minMcap}`, `base_token_market_cap<=${p.maxMcap}`,
    `base_token_holders>=${p.minHolders}`,
    `dlmm_bin_step>=${p.minBinStep}`, `dlmm_bin_step<=${p.maxBinStep}`,
    `fee_active_tvl_ratio>=${p.feeTvl}`,
    `base_token_organic_score>=${p.minOrganic}`,
    `quote_token_organic_score>=${p.minQuoteOrganic}`,
    `base_token_created_at<=${Date.now() - p.minTokenAgeHours * 3_600_000}`,
    "base_token_has_critical_warnings=false", "quote_token_has_critical_warnings=false",
    "base_token_has_high_single_ownership=false",
  ];
}

async function count(fl, extra = "") {
  const url = `${BASE}/pools?page_size=${extra ? 50 : 1}&filter_by=${encodeURIComponent(fl.join("&&"))}&timeframe=30m&category=trending`;
  const res = await fetch(url);
  if (!res.ok) return `HTTP ${res.status}`;
  const data = await res.json();
  if (extra === "list") {
    for (const p of (data.data || []).slice(0, 15)) {
      const x = p.token_x || {};
      console.log(`    ${(p.name||"?").padEnd(22)} tvl=$${Math.round(p.tvl).toString().padEnd(7)} vol30m=$${Math.round(p.volume).toString().padEnd(7)} mcap=$${Math.round(x.market_cap/1000)}k vola=${p.volatility} organic=${x.organic_score}`);
    }
  }
  return data.total ?? "?";
}

console.log(`PROPOSED (vol>=2000, maxTvl 250k, maxMcap 10M): ${await count(filters(P))}`);
console.log(`  ... with minVolume 1000: ${await count(filters({ ...P, minVolume: 1000 }))}`);
console.log(`  ... with minVolume 3000: ${await count(filters({ ...P, minVolume: 3000 }))}`);
console.log(`  ... with minOrganic 40 too: ${await count(filters({ ...P, minOrganic: 40 }))}`);
console.log(`  ... with minHolders 300 too: ${await count(filters({ ...P, minHolders: 300 }))}`);
console.log(`  ... with maxBinStep 250 too: ${await count(filters({ ...P, maxBinStep: 250 }))}`);
console.log(`  ... with minTokenAgeHours 3: ${await count(filters({ ...P, minTokenAgeHours: 3 }))}`);
console.log("\nSurvivor list at proposed values:");
await count(filters(P), "list");
