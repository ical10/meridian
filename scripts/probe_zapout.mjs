// Probe the relay zap-out/order response for an open position.
// Parses the unsigned transactions, extracts every SystemProgram.Transfer
// destination, and queries each address on-chain to identify what it is.

import "../envcrypt.js";
import { VersionedTransaction, SystemInstruction, SystemProgram, PublicKey, Connection } from "@solana/web3.js";
import { Buffer } from "node:buffer";
import { readFileSync } from "node:fs";

const userConfig = JSON.parse(readFileSync("./user-config.json", "utf-8"));
const API_BASE = userConfig.agentMeridianApiUrl || "https://api.agentmeridian.xyz/api";
const RPC_URL = userConfig.rpcUrl;
const AGENT_ID = userConfig.agentId;
const API_KEY = userConfig.publicApiKey;
const WALLET = process.env.WALLET_PRIVATE_KEY ? "8zaAnu8aQvd21nP8dWdQcEzWxev6TzW2poGraHxUZMWP" : null;

const state = JSON.parse(readFileSync("./state.json", "utf-8"));
const openPos = Object.entries(state.positions).find(([, p]) => !p.closed);
if (!openPos) { console.error("no open position to probe"); process.exit(1); }
const [posAddr, p] = openPos;
console.log(`probing position: ${posAddr} (${p.pool_name})`);

// Fetch live position to get current bin range
const liveResp = await fetch(`${API_BASE}/positions/open/raw?owner=${WALLET}`, { headers: { "x-api-key": API_KEY } });
const liveData = await liveResp.json();
const live = (liveData.positions || []).find((x) => x.position === posAddr);
console.log(`bin range: ${live?.lower_bin} → ${live?.upper_bin}`);

const order = await fetch(`${API_BASE}/execution/zap-out/order`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "x-api-key": API_KEY },
  body: JSON.stringify({
    agentId: AGENT_ID,
    idempotencyKey: `probe:${posAddr}:${Date.now()}`,
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

console.log(`order keys: ${Object.keys(order).join(", ")}`);
if (order.error) { console.error(`error: ${order.error}`); process.exit(1); }
const allTxs = [...(order.order?.transactions?.close || []), ...(order.order?.transactions?.swap || [])];
console.log(`unsigned txs: ${allTxs.length} (close=${order.order?.transactions?.close?.length || 0}, swap=${order.order?.transactions?.swap?.length || 0})`);

const conn = new Connection(RPC_URL, "confirmed");
const transferDests = new Set();

for (const [i, serialized] of allTxs.entries()) {
  const bytes = Buffer.from(serialized, "base64");
  const tx = VersionedTransaction.deserialize(bytes);
  const msg = tx.message;
  const allKeys = msg.staticAccountKeys.map((k) => k.toString());
  console.log(`\n--- tx ${i + 1}: ${msg.compiledInstructions.length} instructions, ${allKeys.length} static accounts ---`);

  for (const [j, ix] of msg.compiledInstructions.entries()) {
    const programKey = allKeys[ix.programIdIndex];
    if (programKey !== SystemProgram.programId.toString()) continue;
    const accountKeys = ix.accountKeyIndexes.map((idx) => allKeys[idx]);
    try {
      const decoded = SystemInstruction.decodeInstructionType({
        programId: new PublicKey(programKey),
        keys: accountKeys.map((k) => ({ pubkey: new PublicKey(k), isSigner: false, isWritable: false })),
        data: Buffer.from(ix.data),
      });
      if (decoded === "Transfer") {
        const transfer = SystemInstruction.decodeTransfer({
          programId: new PublicKey(programKey),
          keys: accountKeys.map((k) => ({ pubkey: new PublicKey(k), isSigner: false, isWritable: false })),
          data: Buffer.from(ix.data),
        });
        const lamports = Number(transfer.lamports);
        console.log(`  ix ${j}: SystemProgram.Transfer  ${transfer.fromPubkey.toString()} → ${transfer.toPubkey.toString()}  (${lamports} lamports = ${(lamports / 1e9).toFixed(6)} SOL)`);
        if (transfer.fromPubkey.toString() === WALLET) {
          transferDests.add(transfer.toPubkey.toString());
        }
      }
    } catch (e) { /* not a transfer instruction */ }
  }
}

console.log(`\n=== ${transferDests.size} unique destinations receiving SOL from owner ===`);
for (const dest of transferDests) {
  const info = await conn.getAccountInfo(new PublicKey(dest));
  if (!info) {
    console.log(`  ${dest}: ACCOUNT DOES NOT EXIST (will be created by this tx)`);
    continue;
  }
  console.log(`  ${dest}:`);
  console.log(`    owner: ${info.owner.toString()}`);
  console.log(`    lamports: ${info.lamports}`);
  console.log(`    data size: ${info.data.length} bytes`);
  // Try parsing as token account
  if (info.owner.toString() === "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA") {
    console.log(`    TYPE: SPL Token Account`);
    // Token mint is bytes 0-32 of token account data
    const mintBytes = info.data.subarray(0, 32);
    const mint = new PublicKey(mintBytes).toString();
    console.log(`    token mint: ${mint}`);
    if (mint === "So11111111111111111111111111111111111111112") {
      console.log(`    → WSOL (wrapped SOL) account`);
    }
  } else if (info.owner.toString() === "11111111111111111111111111111111") {
    console.log(`    TYPE: System-owned account (regular SOL wallet or PDA)`);
  } else {
    console.log(`    TYPE: owned by program ${info.owner.toString()}`);
  }
}
