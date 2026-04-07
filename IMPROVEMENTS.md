# Meridian — Potential Optimizations

## Current Resource Profile

| Metric | Value |
|--------|-------|
| Codebase | ~7,637 lines JS (24 files) |
| Disk (code only) | ~1 MB |
| Disk (node_modules) | ~94 MB |
| Memory (cold Node.js) | ~42 MB RSS |
| Memory (all SDKs loaded) | ~94 MB RSS |
| SDK import time | ~380ms (Solana + DLMM) |

## Why Porting to Rust/Go Is Not Worth It

- The workload is I/O-bound (LLM API calls, Solana RPC, cron sleeps) — not CPU-bound
- Meteora DLMM SDK is JavaScript-first; porting would require raw on-chain account parsing
- Expected savings: ~40-50 MB RAM, ~0 improvement in cycle time
- The agent runs idle 99% of the time; 94 MB is fine for any modern server or $5 VPS

## Recommended Optimizations

### 1. Lazy-load the DLMM SDK

The `@meteora-ag/dlmm` and `@solana/web3.js` SDKs account for ~50 MB of runtime memory. Import them on-demand (only when a tool actually needs them) instead of at startup. This keeps the idle footprint around ~45 MB.

### 2. Bundle with esbuild to reduce node_modules

Use `esbuild` to tree-shake and bundle the app into a single file. This can significantly cut the 94 MB `node_modules` footprint on disk and speed up cold starts.

### 3. Use a lighter Solana RPC client

If only balance and transaction queries are needed outside of DLMM operations, consider a minimal RPC wrapper instead of the full `@solana/web3.js` SDK for those paths.

### 4. LLM Tool Call Optimizations

- **Execute deterministic CLOSE/CLAIM in JS** — Management cycle already decides actions via rules (stop loss, take profit, OOR). Currently passes these to the LLM just to execute the tool call. Could call `close_position`/`claim_fees` directly, saving an entire agentLoop per management cycle with rule-triggered actions.
- **Health check without tools** — Hourly health check calls the LLM which then calls tools to gather data. Could pre-load all data and pass to LLM with `tool_choice: "none"`.
- **Remove `get_active_bin` from SCREENER_TOOLS** — Already pre-fetched in JS but still available to the LLM, which sometimes calls it redundantly.
- **Lower maxSteps per role** — Default 20 for all roles, but management/screening rarely use >2-3. Cap MANAGER at 5, SCREENER at 3.
- **Category rotation** — Rotate screening category between `"trending"` / `"new"` / `"volume"` each cycle to widen pool discovery surface.
