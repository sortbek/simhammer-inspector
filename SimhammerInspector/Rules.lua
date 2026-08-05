local addonName, ns = ...

local Rules = {}
ns.Rules = Rules

local function add(findings, slot, kind, severity, state, detail)
  findings[table.getn(findings) + 1] = {
    slot = slot, kind = kind, severity = severity,
    state = state, detail = detail,
  }
end

-- Negative findings may only become "bad" once the evidence is in; until then
-- they are "unknown". This is the heart of section 6 of the spec: a red cell
-- based on data that had not arrived yet is worse than no data at all.
local function stateFor(slotRecord, sources, context)
  if ns.Evidence.isConfirmed(slotRecord, sources, context.minInterval) then
    return "bad"
  end
  return "unknown"
end

-- Hoisted: these were fresh table literals on every finding, on every slot, on
-- every player, on every refresh. isConfirmed only reads them.
local LINK = { "linkComplete" }
local LINK_AND_SOCKETS = { "linkComplete", "socketsKnown" }
local TOOLTIP = { "tooltipComplete" }
local ITEM_LOADED = { "itemLoaded" }
local SOCKETS = { "socketsKnown" }

-- Enchants and gems are ranked identically: wrong season beats wrong quality,
-- both are warnings, both need the same evidence. Only the noun differs, and
-- keeping one copy is what guarantees they stay in step about what "gold" means.
local function checkTierAndQuality(findings, slot, info, noun, slotRecord, context)
  if info.tier ~= ns.Policy.Season.CURRENT_TIER then
    add(findings, slot, "outdated_" .. noun, "warn",
        stateFor(slotRecord, LINK, context),
        noun .. " from " .. info.tier)
  elseif info.quality ~= "gold" then
    add(findings, slot, "low_" .. noun, "warn",
        stateFor(slotRecord, LINK, context),
        noun .. " is " .. info.quality .. " instead of gold")
  end
end

local function checkEnchant(findings, slot, parsed, slotRecord, context)
  if not ns.Policy.Slots.isEnchantable(slot, context.itemSubclass) then return end

  if parsed.enchantID == 0 then
    add(findings, slot, "missing_enchant", "error",
        stateFor(slotRecord, LINK, context),
        "no enchant on an enchantable slot")
    return
  end

  if not context.dataValid then return end

  local info = ns.Data.Enchants[parsed.enchantID]
  if not info then return end

  -- An enchant with no crafting quality cannot be ranked. Death knight
  -- runeforges, engineering tinkers and enchants predating the quality system
  -- all land here, and a runeforged weapon is correctly enchanted -- calling it
  -- outdated is a false accusation. Silence is the only honest answer.
  if not info.quality then return end

  checkTierAndQuality(findings, slot, info, "enchant", slotRecord, context)
end

local function checkGems(findings, slot, parsed, slotRecord, context)
  if not context.dataValid then return end

  for i = 1, 4 do
    local gemID = parsed.gemIDs[i]
    if gemID ~= 0 then
      local info = ns.Data.Gems[gemID]
      if info then
        checkTierAndQuality(findings, slot, info, "gem", slotRecord, context)
      end
    end
  end
end

local function checkUpgrade(findings, slot, upgrade, slotRecord, context)
  -- No upgrade information means UNKNOWN. The spike showed 78 of 184 items have
  -- no upgrade line in the tooltip; they are not all fully upgraded, so staying
  -- silent here is the only correct choice.
  if not upgrade then return end
  if not upgrade.rank or not upgrade.max then return end

  if upgrade.rank < upgrade.max then
    add(findings, slot, "upgrades_left", "warn",
        stateFor(slotRecord, TOOLTIP, context),
        upgrade.rank .. "/" .. upgrade.max .. " " .. tostring(upgrade.track))
  end
end

local function checkSockets(findings, slot, item, slotRecord, context)
  local socketCount = item.socketCount

  -- An unknown socket count means staying silent. You can conclude neither
  -- "empty" nor "missing" from it.
  if type(socketCount) ~= "number" then return end

  if socketCount > 0 then
    -- The EMPTY_SOCKET_* keys from C_Item.GetItemStats mean "there is a socket
    -- here", not "this socket is empty" -- the spike confirmed that a bracer
    -- with a filled Prismatic Socket still returns 1. So the empty count is the
    -- total minus the gems present in the link.
    local empty = socketCount - (item.parsed.gemCount or 0)
    if empty > 0 then
      add(findings, slot, "empty_socket", "error",
          stateFor(slotRecord, LINK_AND_SOCKETS, context),
          empty .. " of " .. socketCount .. " sockets empty")
    end
    return
  end

  if ns.Policy.Slots.isSocketable(slot) then
    add(findings, slot, "missing_socket", "warn",
        stateFor(slotRecord, SOCKETS, context),
        "this slot can take a socket but has none")
  end
end

-- The second parameter is an item record rather than a bare parse result,
-- because three of the checks need hydrated data that is not in the item link.
-- Passing those as separate parameters would grow the signature with every new
-- source.
function Rules.evaluateSlot(slot, item, slotRecord, context)
  local findings = {}

  if not item or not item.parsed then
    -- A two-handed weapon makes an empty off-hand correct, not a finding.
    local isEmptyOffhandWithTwoHander = (slot == 17 and context.twoHanded)
    if not isEmptyOffhandWithTwoHander then
      add(findings, slot, "missing_item", "error",
          stateFor(slotRecord, ITEM_LOADED, context),
          "no item in this slot")
    end
    return findings
  end

  checkEnchant(findings, slot, item.parsed, slotRecord, context)
  checkGems(findings, slot, item.parsed, slotRecord, context)
  checkUpgrade(findings, slot, item.upgrade, slotRecord, context)
  checkSockets(findings, slot, item, slotRecord, context)

  return findings
end

-- Tier and embellishments are the first checks that cannot be judged per slot:
-- you can only say someone wears 3 of 5 tier pieces once all five slots are in.
local function countTierPieces(slots)
  local setIDs = ns.Policy.Season.TIER_SET_IDS
  if not next(setIDs) then return nil end

  local tierSlots = ns.Policy.Slots.TIER
  local worn = 0
  for i = 1, table.getn(tierSlots) do
    local entry = slots[tierSlots[i]]
    if entry and entry.setID and setIDs[entry.setID] then
      worn = worn + 1
    end
  end
  return worn, table.getn(tierSlots)
end

-- Counts embellished items from what the tooltip says about each one, rather
-- than matching bonus IDs against a generated table. The tooltip carries
-- "Unique-Equipped: Embellished (2)" verbatim, which needs no DB2 derivation
-- at all.
--
-- Returns nil when any slot's embellishment status is unknown. Counting only
-- the slots we could read would understate the total and manufacture a
-- "0 of 2 embellishments" finding out of missing data -- the exact fault a live
-- raid surfaced when this was driven by a stub table.
local function countEmbellishments(slots)
  local found, seen = 0, 0
  for _, entry in pairs(slots) do
    if entry.parsed then
      seen = seen + 1
      if entry.embellished == nil then return nil end
      if entry.embellished then found = found + 1 end
    end
  end
  if seen == 0 then return nil end
  return found
end

function Rules.evaluatePlayer(slots, context)
  local findings = {}

  for slot, entry in pairs(slots) do
    local slotFindings = Rules.evaluateSlot(slot, entry, entry.record, context)
    for i = 1, table.getn(slotFindings) do
      findings[table.getn(findings) + 1] = slotFindings[i]
    end
  end

  if not context.dataValid then return findings end

  local worn, total = countTierPieces(slots)
  if worn and worn < total then
    add(findings, nil, "tier_incomplete", "warn", "bad",
        worn .. " of " .. total .. " tier pieces")
  end

  local embellishments = countEmbellishments(slots)
  local maxEmbellishments = ns.Policy.Season.MAX_EMBELLISHMENTS
  if embellishments and embellishments < maxEmbellishments then
    add(findings, nil, "embellishments_missing", "warn", "bad",
        embellishments .. " of " .. maxEmbellishments .. " embellishments")
  end

  return findings
end
