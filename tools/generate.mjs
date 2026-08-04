// Generates SimhammerInspector/Data/*.lua from the wago.tools DB2 CSV snapshots in
// tools/csv/. Run with:
//
//   node tools/generate.mjs                 (uses the checked-in snapshots)
//   node tools/generate.mjs --fetch         (re-downloads them first)
//
// The derivations implemented here were established by measurement, not
// assumption; see docs/superpowers/db2-schema-findings.md.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CSV_DIR = join(ROOT, "tools", "csv");
const DATA_DIR = join(ROOT, "SimhammerInspector", "Data");

// Pin the build. Regenerating against a different build is a deliberate act,
// not something that should happen silently because a hotfix shipped.
const BUILD = "12.0.7.68887";
const VERSION = BUILD.split(".").slice(0, 3).join(".");
const BUILD_NUMBER = BUILD.split(".")[3];

// The expansion number that appears in the enchant quality atlas marker for the
// current season. Midnight is 12.
const CURRENT_EXPANSION = "12";
const CURRENT_TIER = "midnight-s1";
const LEGACY_TIER = "legacy";

// Item.CraftingQualityID values for the current two-tier system. The older
// three-tier system used 1/2/3 and uncrafted items use 0; both are legacy.
const GEM_QUALITY = { "13": "silver", "14": "gold" };

// A class tier set has exactly five pieces. PvP sets have eight, crafted and
// legacy sets have two or three, so the member count alone separates them. The
// remaining question is which generation, and that is answered by the item IDs:
// Midnight season 1 tier items sit in the 249955-250063 block. One curated
// threshold rather than thirteen hand-copied set IDs, and a wrong value shows
// up immediately as too many or too few sets.
const TIER_PIECES = 5;
const CURRENT_TIER_MIN_ITEM_ID = 249000;

const TABLES = {
  SpellItemEnchantment: "SpellItemEnchantment.csv",
  Item: "Item.csv",
  ItemSet: "ItemSet.csv",
};

// --- CSV -------------------------------------------------------------------

// Minimal RFC4180-ish reader: handles quoted fields containing commas and
// escaped quotes, which the DB2 name columns do use.
function parseCsvLine(line) {
  const out = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inQuotes) {
      if (c === '"') {
        if (line[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; }
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ",") {
      out.push(field);
      field = "";
    } else {
      field += c;
    }
  }
  out.push(field);
  return out;
}

function* readCsv(path) {
  const text = readFileSync(path, "utf8");
  const lines = text.split(/\r?\n/);
  const header = parseCsvLine(lines[0]);
  const index = {};
  header.forEach((name, i) => { index[name] = i; });

  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === "") continue;
    const fields = parseCsvLine(lines[i]);
    yield { fields, index, get: (name) => fields[index[name]] };
  }
}

async function fetchTables() {
  for (const [table, file] of Object.entries(TABLES)) {
    const url = `https://wago.tools/db2/${table}/csv?build=${BUILD}`;
    process.stdout.write(`fetching ${table} ... `);
    const res = await fetch(url, { headers: { "User-Agent": "Mozilla/5.0" } });
    if (!res.ok) throw new Error(`${table}: HTTP ${res.status}`);
    const body = await res.text();
    writeFileSync(join(CSV_DIR, file), body);
    console.log(`${(body.length / 1024 / 1024).toFixed(2)} MB`);
  }
}

// --- derivations -----------------------------------------------------------

// Enchant quality lives inside Name_lang as a texture atlas marker:
//   |A:Professions-ChatIcon-Quality-12-Tier2:20:20|a   -> Midnight, gold
//   |A:Professions-ChatIcon-Quality-Tier3:20:20|a      -> older three-tier
// The ID ranges of the two generations overlap, so the marker shape is the only
// reliable discriminator. Never key off an ID range here.
const CURRENT_MARKER = /Professions-ChatIcon-Quality-(\d+)-Tier(\d+)/;
const LEGACY_MARKER = /Professions-ChatIcon-Quality-Tier(\d+)/;

function classifyEnchant(name) {
  const current = name.match(CURRENT_MARKER);
  if (current) {
    const [, expansion, tier] = current;
    if (expansion === CURRENT_EXPANSION) {
      return { quality: tier === "2" ? "gold" : "silver", tier: CURRENT_TIER };
    }
    return { quality: tier === "2" ? "gold" : "silver", tier: LEGACY_TIER };
  }

  const legacy = name.match(LEGACY_MARKER);
  if (legacy) {
    // Older system had three tiers; only the top one counts as gold.
    return { quality: legacy[1] === "3" ? "gold" : "silver", tier: LEGACY_TIER };
  }

  // No crafting quality at all: vanilla-through-Shadowlands enchants, and the
  // engineering tinkers that occupy the same field. Known, therefore outdated
  // rather than unknown.
  return { quality: null, tier: LEGACY_TIER };
}

function buildEnchants() {
  const out = new Map();
  for (const row of readCsv(join(CSV_DIR, TABLES.SpellItemEnchantment))) {
    const id = Number(row.get("ID"));
    if (!Number.isFinite(id) || id === 0) continue;
    const name = row.get("Name_lang") ?? "";
    if (name === "") continue;
    out.set(id, classifyEnchant(name));
  }
  return out;
}

function buildGems() {
  const out = new Map();
  for (const row of readCsv(join(CSV_DIR, TABLES.Item))) {
    if (row.get("ClassID") !== "3") continue;
    const id = Number(row.get("ID"));
    if (!Number.isFinite(id) || id === 0) continue;

    const qualityID = row.get("CraftingQualityID");
    const quality = GEM_QUALITY[qualityID] ?? null;
    const tier = quality ? CURRENT_TIER : LEGACY_TIER;
    out.set(id, { quality, tier });
  }
  return out;
}

function buildTierSets() {
  const out = new Map();
  for (const row of readCsv(join(CSV_DIR, TABLES.ItemSet))) {
    const id = Number(row.get("ID"));
    if (!Number.isFinite(id) || id === 0) continue;

    let members = 0;
    let firstItem = 0;
    for (let i = 0; i <= 16; i++) {
      const itemID = Number(row.get(`ItemID_${i}`));
      if (Number.isFinite(itemID) && itemID > 0) {
        members++;
        if (firstItem === 0) firstItem = itemID;
      }
    }

    if (members !== TIER_PIECES) continue;
    if (firstItem < CURRENT_TIER_MIN_ITEM_ID) continue;

    out.set(id, { name: row.get("Name_lang") ?? "" });
  }
  return out;
}

function writeTierSets(entries) {
  const ids = [...entries.keys()].sort((a, b) => a - b);
  const lines = [
    "local addonName, ns = ...",
    "",
    "ns.Data = ns.Data or {}",
    "",
    `-- GENERATED by tools/generate.mjs from build ${BUILD}. Do not edit by hand.`,
    "-- Class tier sets for the current season: item sets with exactly five",
    "-- pieces whose members are in the current item ID block. PvP sets have",
    "-- eight pieces and older sets have two or three, so they fall out.",
    "ns.Data.TierSets = {",
  ];
  for (const id of ids) {
    lines.push(`  [${id}] = true,  -- ${entries.get(id).name}`);
  }
  lines.push("}", "");
  writeFileSync(join(DATA_DIR, "TierSets.lua"), lines.join("\n"), "utf8");
  return ids.length;
}

// --- output ----------------------------------------------------------------

function luaValue(v) {
  return v === null ? "nil" : `"${v}"`;
}

function writeLuaTable(file, field, entries, note) {
  const ids = [...entries.keys()].sort((a, b) => a - b);
  const lines = [
    "local addonName, ns = ...",
    "",
    "ns.Data = ns.Data or {}",
    "",
    `-- GENERATED by tools/generate.mjs from build ${BUILD}. Do not edit by hand.`,
    `-- ${note}`,
    `ns.Data.${field} = {`,
  ];

  for (const id of ids) {
    const e = entries.get(id);
    lines.push(`  [${id}] = { quality = ${luaValue(e.quality)}, tier = "${e.tier}" },`);
  }

  lines.push("}", "");
  writeFileSync(join(DATA_DIR, file), lines.join("\n"), "utf8");
  return ids.length;
}

function writeVersion() {
  const lines = [
    "local addonName, ns = ...",
    "",
    "ns.Data = ns.Data or {}",
    "",
    "-- GENERATED by tools/generate.mjs. Do not edit by hand.",
    "-- DataVersion degrades on the patch version, never on the build number:",
    "-- build numbers rise almost weekly through hotfixes that touch no items.",
    "ns.Data.Version = {",
    `  version = "${VERSION}",`,
    `  build   = "${BUILD_NUMBER}",`,
    "}",
    "",
  ];
  writeFileSync(join(DATA_DIR, "Version.lua"), lines.join("\n"), "utf8");
}

// --- main ------------------------------------------------------------------

if (process.argv.includes("--fetch")) {
  await fetchTables();
}

for (const file of Object.values(TABLES)) {
  if (!existsSync(join(CSV_DIR, file))) {
    console.error(`missing ${file}; run with --fetch first`);
    process.exit(1);
  }
}

const enchants = buildEnchants();
const gems = buildGems();
const tierSets = buildTierSets();

const enchantCount = writeLuaTable(
  "Enchants.lua", "Enchants", enchants,
  "enchantID -> { quality, tier }; quality is nil for enchants with no crafting tier.");
const gemCount = writeLuaTable(
  "Gems.lua", "Gems", gems,
  "gemID -> { quality, tier }; derived from Item.CraftingQualityID.");
const tierCount = writeTierSets(tierSets);
writeVersion();

const currentEnchants = [...enchants.values()].filter((e) => e.tier === CURRENT_TIER).length;
const currentGems = [...gems.values()].filter((e) => e.tier === CURRENT_TIER).length;

console.log(`Enchants.lua : ${enchantCount} entries (${currentEnchants} current)`);
console.log(`Gems.lua     : ${gemCount} entries (${currentGems} current)`);
console.log(`TierSets.lua : ${tierCount} current tier sets`);
console.log(`Version.lua  : ${VERSION} build ${BUILD_NUMBER}`);

if (tierCount < 10 || tierCount > 16) {
  console.warn(`WARNING: ${tierCount} tier sets is outside the expected 10-16 range.`);
  console.warn("CURRENT_TIER_MIN_ITEM_ID is probably wrong for this build.");
}
