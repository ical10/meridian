/**
 * Pure helpers for building the screening-cycle LLM prompt.
 *
 * This module has zero side effects and no dependencies on the wallet,
 * config, cron jobs, or any I/O — so tests can import it directly without
 * starting the bot.
 */

/**
 * Sanitize an untrusted text blob before embedding into the LLM prompt.
 * - Strips newlines / tabs / suspicious chars (<, >, backticks)
 * - Collapses whitespace
 * - Truncates to maxLen chars
 * - JSON-stringifies the result so any remaining special chars are escaped
 *
 * @param {string} text
 * @param {number} maxLen
 * @returns {string | null}  Returns null if the input is empty/falsy after cleanup.
 */
export function sanitizeUntrustedPromptText(text, maxLen = 200) {
  if (!text) return null;
  const cleaned = String(text)
    .replace(/[\r\n\t]+/g, " ")
    .replace(/\s+/g, " ")
    .replace(/[<>`]/g, "")
    .trim()
    .slice(0, maxLen);
  return cleaned ? JSON.stringify(cleaned) : null;
}

/**
 * Build a single candidate block for the screening prompt.
 *
 * Narrative + memory are truncated to 200 chars (down from 500) to cut prompt tokens.
 * Absent narrative is omitted entirely (no "narrative_untrusted: none" line).
 *
 * @param {object} args
 * @param {object} args.pool      - candidate pool record from getTopCandidates
 * @param {object} [args.sw]      - smart-wallet data from checkSmartWalletsOnPool
 * @param {object} [args.n]       - narrative data from getTokenNarrative
 * @param {object} [args.ti]      - token-info data from getTokenInfo
 * @param {string} [args.mem]     - recalled pool memory
 * @param {number} [args.activeBin] - active bin id
 * @returns {string} multi-line text block suitable for inclusion in the LLM prompt
 */
export function buildCandidateBlock({ pool, sw, n, ti, mem, activeBin }) {
  const botPct = ti?.audit?.bot_holders_pct ?? "?";
  const top10Pct = ti?.audit?.top_holders_pct ?? "?";
  const feesSol = ti?.global_fees_sol ?? "?";
  const launchpad = ti?.launchpad ?? null;
  const priceChange = ti?.stats_1h?.price_change;
  const netBuyers = ti?.stats_1h?.net_buyers;

  const okxParts = [
    pool.risk_level     != null ? `risk=${pool.risk_level}`               : null,
    pool.bundle_pct     != null ? `bundle=${pool.bundle_pct}%`            : null,
    pool.sniper_pct     != null ? `sniper=${pool.sniper_pct}%`            : null,
    pool.suspicious_pct != null ? `suspicious=${pool.suspicious_pct}%`    : null,
    pool.new_wallet_pct != null ? `new_wallets=${pool.new_wallet_pct}%`   : null,
    pool.is_rugpull != null ? `rugpull=${pool.is_rugpull ? "YES" : "NO"}` : null,
    pool.is_wash != null ? `wash=${pool.is_wash ? "YES" : "NO"}` : null,
  ].filter(Boolean).join(", ");
  const okxUnavailable = !okxParts && pool.price_vs_ath_pct == null;

  const okxTags = [
    pool.smart_money_buy    ? "smart_money_buy"    : null,
    pool.kol_in_clusters    ? "kol_in_clusters"    : null,
    pool.dex_boost          ? "dex_boost"          : null,
    pool.dex_screener_paid  ? "dex_screener_paid"  : null,
    pool.dev_sold_all       ? "dev_sold_all(bullish)" : null,
  ].filter(Boolean).join(", ");
  const pvpLine = pool.is_pvp
    ? `  pvp: HIGH — rival ${pool.pvp_rival_name || pool.pvp_symbol} (${pool.pvp_rival_mint?.slice(0, 8)}...) has pool ${pool.pvp_rival_pool?.slice(0, 8)}..., tvl=$${pool.pvp_rival_tvl}, holders=${pool.pvp_rival_holders}, fees=${pool.pvp_rival_fees}SOL`
    : null;

  return [
    `POOL: ${pool.name} (${pool.pool})`,
    `  metrics: bin_step=${pool.bin_step}, fee_pct=${pool.fee_pct}%, fee_tvl=${pool.fee_active_tvl_ratio}, vol=$${pool.volume_window}, tvl=$${pool.active_tvl}, volatility=${pool.volatility}, mcap=$${pool.mcap}, organic=${pool.organic_score}${pool.token_age_hours != null ? `, age=${pool.token_age_hours}h` : ""}`,
    `  audit: top10=${top10Pct}%, bots=${botPct}%, fees=${feesSol}SOL${launchpad ? `, launchpad=${launchpad}` : ""}`,
    pvpLine,
    okxParts ? `  okx: ${okxParts}` : okxUnavailable ? `  okx: unavailable` : null,
    okxTags  ? `  tags: ${okxTags}` : null,
    pool.price_vs_ath_pct != null ? `  ath: price_vs_ath=${pool.price_vs_ath_pct}%${pool.top_cluster_trend ? `, top_cluster=${pool.top_cluster_trend}` : ""}` : null,
    `  smart_wallets: ${sw?.in_pool?.length ?? 0} present${sw?.in_pool?.length ? ` → CONFIDENCE BOOST (${sw.in_pool.map(w => w.name).join(", ")})` : ""}`,
    activeBin != null ? `  active_bin: ${activeBin}` : null,
    priceChange != null ? `  1h: price${priceChange >= 0 ? "+" : ""}${priceChange}%, net_buyers=${netBuyers ?? "?"}` : null,
    n?.narrative ? `  narrative_untrusted: ${sanitizeUntrustedPromptText(n.narrative, 200)}` : null,
    mem ? `  memory_untrusted: ${sanitizeUntrustedPromptText(mem, 200)}` : null,
  ].filter(Boolean).join("\n");
}
