/**
 * Strategy Library — persistent store of LP strategies.
 *
 * Users paste a tweet or description via Telegram.
 * The agent extracts structured criteria and saves it here.
 * During screening, the active strategy's criteria guide token selection and position config.
 */

import fs from "fs";
import { log } from "./logger.js";
import { repoPath } from "./repo-root.js";
import { config } from "./config.js";
import { CONFIG_MAP } from "./config-map.js";

const STRATEGY_FILE = repoPath("strategy-library.json");
const USER_CONFIG_PATH = repoPath("user-config.json");

function load() {
  if (!fs.existsSync(STRATEGY_FILE)) return { active: null, strategies: {} };
  try {
    return JSON.parse(fs.readFileSync(STRATEGY_FILE, "utf8"));
  } catch {
    return { active: null, strategies: {} };
  }
}

function save(data) {
  fs.writeFileSync(STRATEGY_FILE, JSON.stringify(data, null, 2));
}

// ─── Tool Handlers ─────────────────────────────────────────────

/**
 * Add or update a strategy.
 * The agent parses the raw tweet/text and fills in the structured fields.
 */
export function addStrategy({
  id,
  name,
  author = "unknown",
  lp_strategy = "bid_ask",       // "bid_ask" | "spot" | "curve"
  token_criteria = {},           // { min_mcap, min_age_days, requires_kol, notes }
  entry = {},                    // { condition, price_change_threshold_pct, single_side }
  range = {},                    // { type, bins_below_pct, notes }
  exit = {},                     // { take_profit_pct, notes }
  best_for = "",                 // short description of ideal conditions
  raw = "",                      // original tweet/text
}) {
  if (!id || !name) return { error: "id and name are required" };

  const db = load();

  // Slugify id
  const slug = id.toLowerCase().replace(/\s+/g, "_").replace(/[^a-z0-9_]/g, "");

  db.strategies[slug] = {
    id: slug,
    name,
    author,
    lp_strategy,
    token_criteria,
    entry,
    range,
    exit,
    best_for,
    raw,
    added_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };

  // Auto-set as active if it's the first strategy
  if (!db.active) db.active = slug;

  save(db);
  log("strategy", `Strategy saved: ${name} (${slug})`);
  return { saved: true, id: slug, name, active: db.active === slug };
}

/**
 * List all strategies with a summary.
 */
export function listStrategies() {
  const db = load();
  const strategies = Object.values(db.strategies).map((s) => ({
    id: s.id,
    name: s.name,
    author: s.author,
    lp_strategy: s.lp_strategy,
    best_for: s.best_for,
    active: db.active === s.id,
    added_at: s.added_at?.slice(0, 10),
  }));
  return { active: db.active, count: strategies.length, strategies };
}

/**
 * Get full details of a strategy including raw text and all criteria.
 */
export function getStrategy({ id }) {
  if (!id) return { error: "id required" };
  const db = load();
  const strategy = db.strategies[id];
  if (!strategy) return { error: `Strategy "${id}" not found`, available: Object.keys(db.strategies) };
  return { ...strategy, is_active: db.active === id };
}

/**
 * Apply a strategy's config_overrides block to live config + user-config.json.
 * Stateless merge: keys present in overrides clobber existing values; keys
 * absent from overrides are left alone (so manual tunes for unrelated keys
 * survive a strategy switch).
 *
 * Returns an array of [key, before, after] triples for logging/reporting.
 */
function applyConfigOverrides(overrides) {
  if (!overrides || typeof overrides !== "object") return [];

  // Read current user-config so we can persist changes
  let userConfig = {};
  try {
    if (fs.existsSync(USER_CONFIG_PATH)) {
      userConfig = JSON.parse(fs.readFileSync(USER_CONFIG_PATH, "utf8"));
    }
  } catch (e) {
    log("strategy_warn", `applyConfigOverrides: failed to read user-config.json: ${e.message}`);
  }

  const changes = [];
  for (const [key, val] of Object.entries(overrides)) {
    const mapping = CONFIG_MAP[key];
    if (!mapping) {
      log("strategy_warn", `applyConfigOverrides: unknown key "${key}" — skipping`);
      continue;
    }
    const [section, field, persistedPath] = mapping;
    // Mutate live config object
    const before = config[section]?.[field];
    if (config[section] !== undefined) config[section][field] = val;
    // Persist to user-config.json. If a persistedPath exists, use it; otherwise
    // user-config.json holds the flat key directly (most common case).
    if (Array.isArray(persistedPath)) {
      // Nested persisted path, e.g. ["chartIndicators","enabled"]
      let cursor = userConfig;
      for (let i = 0; i < persistedPath.length - 1; i++) {
        const seg = persistedPath[i];
        if (cursor[seg] === undefined || cursor[seg] === null) cursor[seg] = {};
        cursor = cursor[seg];
      }
      cursor[persistedPath[persistedPath.length - 1]] = val;
    } else {
      userConfig[key] = val;
    }
    changes.push([key, before, val]);
  }

  // Persist user-config.json if anything changed
  if (changes.length > 0) {
    try {
      fs.writeFileSync(USER_CONFIG_PATH, JSON.stringify(userConfig, null, 2));
    } catch (e) {
      log("strategy_warn", `applyConfigOverrides: failed to write user-config.json: ${e.message}`);
    }
  }
  return changes;
}

/**
 * Set the active strategy used during screening cycles.
 * If the strategy has a `config_overrides` block, those values are applied
 * to live config and persisted to user-config.json (clobber + stateless merge).
 */
export function setActiveStrategy({ id }) {
  if (!id) return { error: "id required" };
  const db = load();
  if (!db.strategies[id]) return { error: `Strategy "${id}" not found`, available: Object.keys(db.strategies) };
  db.active = id;
  save(db);
  log("strategy", `Active strategy set to: ${db.strategies[id].name}`);

  // Apply config_overrides if present
  const overrides = db.strategies[id].config_overrides;
  const changes = applyConfigOverrides(overrides);
  if (changes.length > 0) {
    log("strategy", `Applied ${changes.length} config_overrides for ${db.strategies[id].name}:`);
    for (const [key, before, after] of changes) {
      log("strategy", `  ${key}: ${JSON.stringify(before)} → ${JSON.stringify(after)}`);
    }
  }

  return {
    active: id,
    name: db.strategies[id].name,
    config_overrides_applied: changes.map(([k, b, a]) => ({ key: k, before: b, after: a })),
  };
}

/**
 * Remove a strategy.
 */
export function removeStrategy({ id }) {
  if (!id) return { error: "id required" };
  const db = load();
  if (!db.strategies[id]) return { error: `Strategy "${id}" not found` };
  const name = db.strategies[id].name;
  delete db.strategies[id];
  if (db.active === id) db.active = Object.keys(db.strategies)[0] || null;
  save(db);
  log("strategy", `Strategy removed: ${name}`);
  return { removed: true, id, name, new_active: db.active };
}

/**
 * Get the currently active strategy — used by screening cycle.
 */
export function getActiveStrategy() {
  const db = load();
  if (!db.active || !db.strategies[db.active]) return null;
  return db.strategies[db.active];
}
