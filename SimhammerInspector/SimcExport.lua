local addonName, ns = ...

local SimcExport = {}
ns.SimcExport = SimcExport

-- Builds SimulationCraft profiles. Pure: parsed item data and player metadata
-- in, text out, no WoW API and no state. That is what lets the format be tested
-- against real captured item links rather than discovered to be malformed in a
-- raid.
--
-- The format is copied from the SimulationCraft addon's own core.lua rather than
-- reconstructed, since it is the only authority on what SimC will accept.

-- Modifier pair types, from the reference implementation.
local MOD_DROP_LEVEL           = 9
local MOD_CONTENT_TUNING       = 28
local MOD_CRAFT_STATS_1        = 29
local MOD_CRAFT_STATS_2        = 30
local MOD_REDIRECTED_BASE_STATS = 64

-- Lowercase, spaces to underscores, then drop every byte that is not a lowercase
-- letter, a digit or an underscore. Copied from the reference implementation
-- rather than approximated with a pattern: realm names carry apostrophes and
-- accented characters, and a gsub that only handles the cases you thought of
-- produces a server= line SimC will not match.
function SimcExport.tokenize(text)
  if type(text) ~= "string" then return "" end
  local lowered = string.gsub(string.lower(text), " ", "_")
  -- A complement class, not an enumeration: it discards every byte outside the
  -- set by construction, so there is no list of accented characters to keep up
  -- with. That distinction is what makes this safe where a pattern listing the
  -- characters you happened to think of would not be.
  return (string.gsub(lowered, "[^a-z0-9_]", ""))
end

function SimcExport.itemLine(simcSlot, parsed)
  if not parsed then return nil end

  local parts = { simcSlot .. "=,id=" .. parsed.itemID }

  if parsed.enchantID and parsed.enchantID > 0 then
    parts[table.getn(parts) + 1] = "enchant_id=" .. parsed.enchantID
  end

  -- Trailing zeros are stripped, but an empty slot between two gems is kept:
  -- the position carries meaning.
  local lastGem = 0
  for i = 1, 4 do
    if parsed.gemIDs[i] ~= 0 then lastGem = i end
  end
  if lastGem > 0 then
    local gems = {}
    for i = 1, lastGem do gems[i] = parsed.gemIDs[i] end
    parts[table.getn(parts) + 1] = "gem_id=" .. table.concat(gems, "/")
  end

  if table.getn(parsed.bonusIDs) > 0 then
    parts[table.getn(parts) + 1] = "bonus_id=" .. table.concat(parsed.bonusIDs, "/")
  end

  -- Modifier pairs carry several distinct things; the crafted stat pair is
  -- collected, the rest are emitted individually.
  local craftedStats = {}
  if parsed.modifiers[MOD_CRAFT_STATS_1] then
    craftedStats[table.getn(craftedStats) + 1] = parsed.modifiers[MOD_CRAFT_STATS_1]
  end
  if parsed.modifiers[MOD_CRAFT_STATS_2] then
    craftedStats[table.getn(craftedStats) + 1] = parsed.modifiers[MOD_CRAFT_STATS_2]
  end

  if parsed.modifiers[MOD_DROP_LEVEL] then
    parts[table.getn(parts) + 1] = "drop_level=" .. parsed.modifiers[MOD_DROP_LEVEL]
  end
  if parsed.modifiers[MOD_CONTENT_TUNING] then
    parts[table.getn(parts) + 1] = "content_tuning=" .. parsed.modifiers[MOD_CONTENT_TUNING]
  end
  if table.getn(craftedStats) > 0 then
    parts[table.getn(parts) + 1] = "crafted_stats=" .. table.concat(craftedStats, "/")
  end
  if parsed.modifiers[MOD_REDIRECTED_BASE_STATS] then
    parts[table.getn(parts) + 1] =
      "redirected_base_stats=" .. parsed.modifiers[MOD_REDIRECTED_BASE_STATS]
  end

  if parsed.gemBonusIDs and table.getn(parsed.gemBonusIDs) > 0 then
    parts[table.getn(parts) + 1] = "gem_bonus_id=" .. table.concat(parsed.gemBonusIDs, "/")
  end

  if parsed.craftingQuality then
    parts[table.getn(parts) + 1] = "crafting_quality=" .. parsed.craftingQuality
  end

  return table.concat(parts, ",")
end

-- Returns the profile text, or nil plus a reason. A profile without talents sims
-- as an unspecced character and produces a number that looks real, so refusing
-- beats exporting something quietly wrong.
function SimcExport.profile(player)
  if not player then return nil, "no player" end
  if not player.talents or player.talents == "" then
    return nil, "no talents captured"
  end
  if not player.class or not player.name then
    return nil, "missing class or name"
  end
  -- An empty spec= line is as unusable to SimC as a missing talent string, and
  -- just as easy to miss in a wall of profiles.
  if not player.spec or player.spec == "" then
    return nil, "no spec captured"
  end

  local lines = {
    string.format("# %s - %s - %s/%s",
                  player.name, player.spec or "unknown",
                  player.region or "", player.realm or ""),
    SimcExport.tokenize(player.class) .. '="' .. player.name .. '"',
    "level=" .. tostring(player.level or 0),
    "race=" .. SimcExport.tokenize(player.race),
    "region=" .. SimcExport.tokenize(player.region),
    "server=" .. SimcExport.tokenize(player.realm),
    "role=" .. (player.role or "attack"),
    "spec=" .. SimcExport.tokenize(player.spec),
    "talents=" .. player.talents,
    "",
  }

  for i = 1, table.getn(player.slots or {}) do
    local slot = player.slots[i]
    local line = SimcExport.itemLine(slot.simcSlot, slot.parsed)
    if line then
      lines[table.getn(lines) + 1] = line
    end
  end

  return table.concat(lines, "\n")
end

function SimcExport.bundle(players)
  local profiles, skipped = {}, {}

  for i = 1, table.getn(players) do
    local p = players[i]
    local text, err = SimcExport.profile(p)
    if text then
      profiles[table.getn(profiles) + 1] = text
    else
      skipped[table.getn(skipped) + 1] = { name = p.name or "?", reason = err }
    end
  end

  return table.concat(profiles, "\n\n"), skipped
end
