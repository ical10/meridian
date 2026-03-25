// Diagnostic: run ONE screening evaluation and capture everything.
// Logs the candidate input, every LLM step, tool calls, and what the LLM returns.

import { config } from "../config.js";
import { getTopCandidates } from "../tools/screening.js";

const VERBOSE_LOG = "/tmp/screening_diag.log";
import fs from "fs";
fs.writeFileSync(VERBOSE_LOG, "");

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  fs.appendFileSync(VERBOSE_LOG, line + "\n");
}

log("=== SCREENING DIAGNOSTIC START ===");
log(`Model: ${config.llm.screeningModel}`);
log(`Strategy: ${config.strategy.strategy}, category: ${config.screening.category}`);
log(`Filters: feeActiveTvlBands=${JSON.stringify(config.screening.feeActiveTvlBands)}, minVolume=${config.screening.minVolume}, minTvl=${config.screening.minTvl}`);
log("");

// Step 1: Get candidates from screening
log("--- STEP 1: getTopCandidates ---");
const startCands = Date.now();
const candResult = await getTopCandidates({ limit: 10 });
const candidates = candResult?.candidates || candResult?.pools || [];
log(`  Took ${Date.now() - startCands}ms`);
log(`  Candidates returned: ${candidates.length}`);
log(`  Filtered examples: ${(candResult?.filtered_examples || []).slice(0, 5).map(e => `${e.name}: ${e.reason}`).join("; ")}`);

if (candidates.length === 0) {
  log("\n  No candidates — diagnostic ends here.");
  log(`  Full filtered list: ${(candResult?.all_filtered || candResult?.filtered_examples || []).slice(0, 15).map(e => `${e.name}: ${e.reason}`).join("\n    ")}`);
  process.exit(0);
}

candidates.slice(0, 3).forEach((c, i) => {
  log(`\n  Candidate ${i+1}: ${c.name || c.pair}`);
  log(`    fee/TVL: ${c.fee_active_tvl_ratio} | volatility: ${c.volatility} | volume: $${c.volume} | mcap: $${(c.base?.mcap || 0)}`);
});

log("\n--- STEP 2: feed candidates to a minimal LLM call to test responsiveness ---");

// Manually invoke a simple LLM call with our model
import OpenAI from "openai";
const openai = new OpenAI({
  apiKey: process.env.LLM_API_KEY || config.llm?.apiKey,
  baseURL: process.env.LLM_BASE_URL || "https://api.deepseek.com/v1",
});

const testPrompt = `You have ${candidates.length} pool candidates. Respond with a single word: "received".`;

log(`  Sending minimal prompt to ${config.llm.screeningModel}...`);
const start = Date.now();
try {
  const resp = await openai.chat.completions.create({
    model: config.llm.screeningModel,
    messages: [{ role: "user", content: testPrompt }],
    max_tokens: 50,
  });
  log(`  Response in ${Date.now() - start}ms`);
  log(`  Content: ${JSON.stringify(resp.choices?.[0]?.message?.content || "<empty>")}`);
  log(`  Finish reason: ${resp.choices?.[0]?.finish_reason}`);
  log(`  Usage: ${JSON.stringify(resp.usage)}`);
} catch (e) {
  log(`  ERROR: ${e.message}`);
}

log("\n--- STEP 3: Test with TOOL CALL request ---");
const toolDef = {
  type: "function",
  function: {
    name: "test_tool",
    description: "A test tool",
    parameters: { type: "object", properties: { msg: { type: "string" } }, required: ["msg"] }
  }
};

log(`  Sending request WITH tool_choice=required...`);
const start2 = Date.now();
try {
  const resp2 = await openai.chat.completions.create({
    model: config.llm.screeningModel,
    messages: [{ role: "user", content: "Call test_tool with msg='hello'." }],
    tools: [toolDef],
    tool_choice: "required",
    max_tokens: 100,
  });
  log(`  Response in ${Date.now() - start2}ms`);
  log(`  Content: ${JSON.stringify(resp2.choices?.[0]?.message?.content)}`);
  log(`  Tool calls: ${JSON.stringify(resp2.choices?.[0]?.message?.tool_calls)}`);
  log(`  Finish reason: ${resp2.choices?.[0]?.finish_reason}`);
} catch (e) {
  log(`  tool_choice=required FAILED: ${e.message}`);
  log(`  trying tool_choice=auto fallback...`);
  try {
    const resp3 = await openai.chat.completions.create({
      model: config.llm.screeningModel,
      messages: [{ role: "user", content: "Call test_tool with msg='hello'." }],
      tools: [toolDef],
      tool_choice: "auto",
      max_tokens: 100,
    });
    log(`  Auto-mode response: ${JSON.stringify(resp3.choices?.[0]?.message?.content || "<empty>")}`);
    log(`  Auto-mode tool_calls: ${JSON.stringify(resp3.choices?.[0]?.message?.tool_calls)}`);
    log(`  Auto-mode finish_reason: ${resp3.choices?.[0]?.finish_reason}`);
  } catch (e2) {
    log(`  Auto fallback also failed: ${e2.message}`);
  }
}

log("\n=== DIAGNOSTIC COMPLETE ===");
log(`Full log: ${VERBOSE_LOG}`);
