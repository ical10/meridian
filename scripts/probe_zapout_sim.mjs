// Probe why the relay zap-out SWAP leg fails simulation while the CLOSE leg passes.
// Read-only: fetches an order, simulates each unsigned tx, decodes the failing
// instruction's program and the token accounts it touches. Nothing is submitted.

import "../envcrypt.js";
import { VersionedTransaction, PublicKey, Connection } from "@solana/web3.js";
import { Buffer } from "node:buffer";
import { readFileSync } from "node:fs";

const userConfig = JSON.parse(readFileSync("./user-config.json", "utf-8"));
const API_BASE = userConfig.agentMeridianApiUrl || "https://api.agentmeridian.xyz/api";
const RPC_URL = userConfig.rpcUrl;
const AGENT_ID = userConfig.agentId;
const API_KEY = userConfig.publicApiKey;
const WALLET = "8zaAnu8aQvd21nP8dWdQcEzWxev6TzW2poGraHxUZMWP";

const state = JSON.parse(readFileSync("./state.json", "utf-8"));
const openPos = Object.entries(state.positions).find(([, p]) => !p.closed);
if (!openPos) { console.error("no open position to probe"); process.exit(1); }
const [posAddr, p] = openPos;
console.log(`probing position: ${posAddr} (${p.pool_name})`);

const liveResp = await fetch(`${API_BASE}/positions/open/raw?owner=${WALLET}`, { headers: { "x-api-key": API_KEY } });
const liveData = await liveResp.json();
const live = (liveData.positions || []).find((x) => x.position === posAddr);
console.log(`bin range: ${live?.lower_bin} -> ${live?.upper_bin}, base_mint: ${live?.base_mint}`);

const order = await fetch(`${API_BASE}/execution/zap-out/order`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "x-api-key": API_KEY },
  body: JSON.stringify({
    agentId: AGENT_ID,
    idempotencyKey: `probe-sim:${posAddr}:${Date.now()}`,
    positionId: posAddr,
    owner: WALLET,
    bps: 10000,
    slippageBps: 5000,
    output: "allToken1",
    provider: "OKX",
    type: "meteora",
    fromBinId: live?.lower_bin ?? -887272,
    toBinId: live?.upper_bin ?? 887272,
  }),
}).then((r) => r.json());

if (order.error) { console.error(`order error: ${order.error}`); process.exit(1); }
const closeTxs = order.order?.transactions?.close || [];
const swapTxs = order.order?.transactions?.swap || [];
console.log(`order ok: close=${closeTxs.length} swap=${swapTxs.length}`);

const conn = new Connection(RPC_URL, "confirmed");

async function probe(label, serialized) {
  const tx = VersionedTransaction.deserialize(Buffer.from(serialized, "base64"));
  const keys = tx.message.staticAccountKeys.map((k) => k.toString());
  console.log(`\n=== ${label}: ${tx.message.compiledInstructions.length} instructions ===`);
  tx.message.compiledInstructions.forEach((ix, i) => {
    console.log(`  ix ${i}: program ${keys[ix.programIdIndex]}`);
  });
  const sim = await conn.simulateTransaction(tx, { sigVerify: false, replaceRecentBlockhash: true });
  if (sim.value.err) {
    console.log(`  SIM FAILED: ${JSON.stringify(sim.value.err)}`);
    const failedIdx = sim.value.err?.InstructionError?.[0];
    if (failedIdx != null) {
      const ix = tx.message.compiledInstructions[failedIdx];
      console.log(`  failing instruction ${failedIdx} program: ${keys[ix.programIdIndex]}`);
      const ixAccounts = ix.accountKeyIndexes.map((idx) => keys[idx]).filter(Boolean);
      for (const acct of ixAccounts.slice(0, 12)) {
        const info = await conn.getAccountInfo(new PublicKey(acct));
        let detail = "MISSING (does not exist)";
        if (info) {
          detail = `owner=${info.owner.toString().slice(0, 12)} lamports=${info.lamports}`;
          if (info.owner.toString() === "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" && info.data.length >= 72) {
            const mint = new PublicKey(info.data.subarray(0, 32)).toString();
            const amount = info.data.readBigUInt64LE(64);
            detail += ` TOKEN mint=${mint.slice(0, 8)} amount=${amount}`;
          }
        }
        console.log(`    acct ${acct.slice(0, 12)}: ${detail}`);
      }
    }
    const logs = sim.value.logs || [];
    console.log(`  last sim logs:\n    ${logs.slice(-8).join("\n    ")}`);
  } else {
    console.log(`  SIM OK (unitsConsumed=${sim.value.unitsConsumed})`);
  }
}

for (const [i, s] of closeTxs.entries()) await probe(`close ${i + 1}`, s);
for (const [i, s] of swapTxs.entries()) await probe(`swap ${i + 1}`, s);
