/**
 * Prompt-size regression harness for the screening cycle.
 *
 * Builds candidate blocks with synthetic but realistic data and verifies the
 * total prompt body stays under the expected token budget after the
 * narrative/memory truncation + top-5 limit changes.
 *
 * Run: node test/test-screening-prompt.js
 *
 * Exits non-zero if the total prompt body exceeds BUDGET_TOKENS.
 */

import { buildCandidateBlock } from "../screening-prompt.js";

// Approximate tokenizer: OpenAI-family models average ~4 chars per token for English.
// Not exact but close enough to catch regressions.
function approxTokens(str) {
  return Math.ceil(str.length / 4);
}

// ── Synthetic data generators ────────────────────────────────────────

const LONG_NARRATIVE =
  "A freshly graduated pump.fun token riding a viral Twitter thread with 4M+ views. " +
  "The meme centers on an absurd Doomer Wojak doorbell scenario. Strong organic buying pressure " +
  "in the first 2 hours post-graduation, with notable KOL pickup including CT influencers. " +
  "No dev-owned wallets detected in holder distribution. Dev has not sold. Community is " +
  "actively minting related derivatives. Risk factors: meme fatigue, narrative decay, post-" +
  "graduation volatility. Entry signal moderate — volume sustained above $30k/1h window.";

const LONG_MEMORY =
  "DEPLOY HISTORY: 4 prior deploys, 2 wins / 2 losses, avg PnL +0.87%, win rate 50%, " +
  "adjusted win rate 45% (excluding outliers). Most recent close: +2.3% after 43 min hold, " +
  "trailing TP fired. 2 prior OOR closes within 15-min window. RECENT TREND: PnL drift +1.2% " +
  "over last 3 cycles, OOR in 1/3 cycles. NOTES: 'watch for volume dip after 1h, often leads " +
  "to range break downward'. Previous winners entered when fee/TVL >0.15. Avoid during late US " +
  "session — historical pattern of dump.";

function makeCandidate(i, { narrative = LONG_NARRATIVE, memory = LONG_MEMORY } = {}) {
  const pool = {
    name: `TestToken${i}-SOL`,
    pool: `PoolAddress${i}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`.slice(0, 44),
    bin_step: 100,
    fee_pct: 1.0,
    fee_active_tvl_ratio: 0.12,
    volume_window: 45000,
    active_tvl: 30000,
    volatility: 2.1,
    mcap: 850000,
    organic_score: 78,
    token_age_hours: 6,
    // OKX enrichment present
    risk_level: 2,
    bundle_pct: 5.8,
    sniper_pct: 1.6,
    suspicious_pct: 0.001,
    new_wallet_pct: 3.2,
    is_rugpull: false,
    is_wash: false,
    smart_money_buy: true,
    kol_in_clusters: false,
    dex_boost: true,
    dex_screener_paid: false,
    dev_sold_all: false,
    price_vs_ath_pct: 74,
    top_cluster_trend: "buying",
    is_pvp: false,
    base: { mint: `BaseTokenMint${i}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`.slice(0, 44) },
  };
  const sw = { in_pool: [] };
  const n = narrative ? { narrative } : null;
  const ti = {
    audit: { bot_holders_pct: 18, top_holders_pct: 32 },
    global_fees_sol: 45.2,
    launchpad: "pump.fun",
    stats_1h: { price_change: 6.4, net_buyers: 287 },
    holders: 1420,
  };
  const mem = memory;
  const activeBin = -1234;
  return { pool, sw, n, ti, mem, activeBin };
}

// ── Test execution ───────────────────────────────────────────────────

const BUDGET_TOKENS = 3500; // target after optimization (was ~7000+ before)
const N_CANDIDATES = 5;     // matches runtime limit

console.log("=== Screening prompt size regression test ===\n");

const candidates = Array.from({ length: N_CANDIDATES }, (_, i) => makeCandidate(i + 1));
const blocks = candidates.map(buildCandidateBlock);
const joined = blocks.join("\n\n");

// Sample static portions that go into the screening prompt alongside candidate blocks
const STATIC_PROMPT_TAIL = `
STEPS:
1. Pick the best candidate (metrics, smart wallets, narrative).
2. Call deploy_position (active_bin is pre-fetched above).
   bins_below = round(35 + (volatility/5)*55) clamped to [35,90].
   Single-side SOL: amount_y only, amount_x=0, bins_above=0.
3. Report on success:
🚀 DEPLOYED <pool name> (<pool address>)
◎ <amount> SOL | <strategy> | bin <active_bin>
Range cover: <range_coverage.downside_pct>% down / <range_coverage.upside_pct>% up (use tool result, don't compute)
Fee/TVL: <x>% | Vol: $<x> | TVL: $<x> | Volatility: <x> | Organic: <x> | Mcap: $<x>
Top10: <x>% | Bots: <x>% | Fees: <x> SOL | Smart wallets: <names or none>
OKX: <risk flags if present, else "unavailable">
Why: <1-2 sentences>

4. If nothing qualifies, report:
⛔ NO DEPLOY
Best: <name or none>
Why: <1-2 sentences>
Rejected: <flat list of names with 1-phrase reasons>`;

const blockTokens = approxTokens(joined);
const tailTokens = approxTokens(STATIC_PROMPT_TAIL);
const totalTokens = blockTokens + tailTokens;

console.log(`Generated ${blocks.length} candidate blocks.`);
console.log(`Candidate-blocks body:  ${joined.length} chars  ~${blockTokens} tokens`);
console.log(`Output format tail:     ${STATIC_PROMPT_TAIL.length} chars  ~${tailTokens} tokens`);
console.log(`Total body (no system): ~${totalTokens} tokens`);
console.log(`Budget:                 ${BUDGET_TOKENS} tokens\n`);

// Also show per-block token breakdown
console.log("Per-block sizes:");
blocks.forEach((b, i) => {
  console.log(`  #${i + 1}: ${b.length} chars  ~${approxTokens(b)} tokens`);
});

console.log("\n--- First block (for visual inspection) ---");
console.log(blocks[0]);
console.log("--- end first block ---\n");

// Regression check: narrative in block must be truncated to ~200 chars
const firstBlock = blocks[0];
const narrativeMatch = firstBlock.match(/narrative_untrusted: "([^"]*)"/);
if (narrativeMatch) {
  const narrativeLen = narrativeMatch[1].length;
  console.log(`Narrative in first block: ${narrativeLen} chars (expected ≤ 200)`);
  if (narrativeLen > 210) {
    // small wiggle room for tokenization edge cases
    console.error(`\n❌ FAIL: narrative length ${narrativeLen} exceeds 200 (old limit was 500)`);
    process.exit(1);
  }
}

// Regression check: memory in block must also be truncated
const memoryMatch = firstBlock.match(/memory_untrusted: "([^"]*)"/);
if (memoryMatch) {
  const memoryLen = memoryMatch[1].length;
  console.log(`Memory in first block:    ${memoryLen} chars (expected ≤ 200)`);
  if (memoryLen > 210) {
    console.error(`\n❌ FAIL: memory length ${memoryLen} exceeds 200`);
    process.exit(1);
  }
}

// Regression check: absent narrative should be omitted (no "narrative_untrusted: none")
const omittedNarrativeCandidate = makeCandidate(99, { narrative: null });
const omittedBlock = buildCandidateBlock(omittedNarrativeCandidate);
if (omittedBlock.includes("narrative_untrusted")) {
  console.error(`\n❌ FAIL: narrative_untrusted line should be omitted when narrative is absent`);
  console.error(`Got: ${omittedBlock}`);
  process.exit(1);
}
console.log(`Absent-narrative candidate:  narrative line correctly omitted ✓`);

// Final budget check
if (totalTokens > BUDGET_TOKENS) {
  console.error(`\n❌ FAIL: total tokens ${totalTokens} exceeds budget ${BUDGET_TOKENS}`);
  process.exit(1);
}

console.log(`\n✅ PASS: total body ~${totalTokens} tokens within ${BUDGET_TOKENS} budget`);
