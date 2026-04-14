/**
 * Output-format sanity test for the compacted screening report template.
 *
 * The LLM is expected to emit either a "🚀 DEPLOYED ..." or "⛔ NO DEPLOY ..."
 * block. Downstream Telegram readers depend on certain fields being present:
 *   - Pool name + address (for navigation / verification)
 *   - Range coverage numbers (for UX display)
 *   - Core market metrics (fee/TVL, volume, volatility)
 *
 * This test feeds a few synthetic LLM outputs through lightweight parsing
 * and confirms the required fields are parseable.
 *
 * Run: node test/test-prompt-shapes.js
 *
 * Exits non-zero if any required field is missing from a DEPLOYED sample
 * or any required field is missing from a NO DEPLOY sample.
 */

// ── Synthetic LLM outputs matching the new compact template ──────────

const DEPLOYED_SAMPLE_1 = `🚀 DEPLOYED TestToken-SOL (PoolAddress1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx)
◎ 0.8 SOL | spot | bin -1234
Range cover: 42.1% down / 0.0% up (use tool result, don't compute)
Fee/TVL: 0.12% | Vol: $45000 | TVL: $30000 | Volatility: 2.1 | Organic: 78 | Mcap: $850000
Top10: 32% | Bots: 18% | Fees: 45.2 SOL | Smart wallets: none
OKX: risk=2, bundle=5.8%, no rugpull, no wash
Why: Best fee/TVL in set with solid organic 78 and growing 1h volume. Pump.fun origin matches sniper strategy.`;

const DEPLOYED_SAMPLE_2 = `🚀 DEPLOYED SIZE-SOL (9AvytnUKxyzxyzxyzxyzxyzxyzxyzxyzxyzxyzxyzxyzx)
◎ 1.0 SOL | bid_ask | bin -507
Range cover: 35% down / 0% up
Fee/TVL: 0.18% | Vol: $12000 | TVL: $8500 | Volatility: 1.8 | Organic: 82 | Mcap: $450000
Top10: 28% | Bots: 22% | Fees: 18 SOL | Smart wallets: whale_1, whale_2
OKX: unavailable
Why: Smart wallets present. Fresh launch with sustained volume.`;

const NO_DEPLOY_SAMPLE_1 = `⛔ NO DEPLOY
Best: CHIBI-SOL
Why: All candidates have poor historical pool memory with negative avg PnL.
Rejected: CHIBI-SOL: -15% avg PnL in memory; BULL-SOL: 8 failed deploys; Harry-SOL: dev sold all.`;

const NO_DEPLOY_SAMPLE_2 = `⛔ NO DEPLOY
Best: none
Why: No candidates passed volatility + holder filters this cycle.
Rejected: `;

// ── Parsers for required fields ──────────────────────────────────────

function parseDeployed(text) {
  const headerMatch = text.match(/🚀\s*DEPLOYED\s+([^\s(]+)\s*\(([^)]+)\)/);
  const amountMatch = text.match(/◎\s*([\d.]+)\s*SOL\s*\|\s*(\w+)\s*\|\s*bin\s*(-?\d+)/);
  const rangeMatch  = text.match(/Range cover:\s*([\d.]+)%\s*down\s*\/\s*([\d.]+)%\s*up/i);
  const feeTvlMatch = text.match(/Fee\/TVL:\s*([\d.]+)%/);
  const volMatch    = text.match(/Vol:\s*\$?([\d.]+)/);
  const volatMatch  = text.match(/Volatility:\s*([\d.]+)/);
  const whyMatch    = text.match(/Why:\s*(.+)/);

  return {
    poolName:   headerMatch?.[1] ?? null,
    poolAddr:   headerMatch?.[2] ?? null,
    amount:     amountMatch ? parseFloat(amountMatch[1]) : null,
    strategy:   amountMatch?.[2] ?? null,
    activeBin:  amountMatch ? parseInt(amountMatch[3]) : null,
    downsidePct: rangeMatch ? parseFloat(rangeMatch[1]) : null,
    upsidePct:   rangeMatch ? parseFloat(rangeMatch[2]) : null,
    feeTvlPct:   feeTvlMatch ? parseFloat(feeTvlMatch[1]) : null,
    volume:      volMatch ? parseFloat(volMatch[1]) : null,
    volatility:  volatMatch ? parseFloat(volatMatch[1]) : null,
    why:         whyMatch?.[1]?.trim() ?? null,
  };
}

function parseNoDeploy(text) {
  const bestMatch = text.match(/Best:\s*(\S[^\n]*)/);
  const whyMatch  = text.match(/Why:\s*(.+)/);
  return {
    best: bestMatch?.[1]?.trim() ?? null,
    why:  whyMatch?.[1]?.trim() ?? null,
  };
}

// ── Test runner ──────────────────────────────────────────────────────

let failures = 0;

function assert(cond, msg) {
  if (!cond) {
    console.error(`  ❌ ${msg}`);
    failures += 1;
  } else {
    console.log(`  ✓ ${msg}`);
  }
}

console.log("=== Deployed sample 1 ===");
{
  const p = parseDeployed(DEPLOYED_SAMPLE_1);
  assert(p.poolName === "TestToken-SOL", "pool name parsed");
  assert(p.poolAddr && p.poolAddr.length >= 40, "pool address parsed");
  assert(p.amount === 0.8, "deploy amount parsed");
  assert(p.strategy === "spot", "strategy parsed");
  assert(Number.isInteger(p.activeBin) && p.activeBin < 0, "active bin parsed");
  assert(p.downsidePct != null, "downside pct parsed");
  assert(p.upsidePct != null, "upside pct parsed");
  assert(p.feeTvlPct != null, "fee/TVL parsed");
  assert(p.volume != null, "volume parsed");
  assert(p.volatility != null, "volatility parsed");
  assert(p.why && p.why.length > 10, "why explanation present");
}

console.log("\n=== Deployed sample 2 ===");
{
  const p = parseDeployed(DEPLOYED_SAMPLE_2);
  assert(p.poolName === "SIZE-SOL", "pool name parsed");
  assert(p.amount === 1.0, "deploy amount parsed");
  assert(p.strategy === "bid_ask", "strategy parsed");
  assert(p.downsidePct === 35, "35% downside parsed even without decimal");
}

console.log("\n=== NO DEPLOY sample 1 ===");
{
  const p = parseNoDeploy(NO_DEPLOY_SAMPLE_1);
  assert(p.best === "CHIBI-SOL", "best candidate parsed");
  assert(p.why && p.why.length > 10, "why explanation present");
}

console.log("\n=== NO DEPLOY sample 2 ===");
{
  const p = parseNoDeploy(NO_DEPLOY_SAMPLE_2);
  assert(p.best === "none", "'none' is an accepted best value");
  assert(p.why && p.why.length > 10, "why explanation present");
}

console.log();
if (failures > 0) {
  console.error(`❌ FAIL: ${failures} assertion(s) failed`);
  process.exit(1);
}
console.log("✅ PASS: all required fields parseable in all samples");
