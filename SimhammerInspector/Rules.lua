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
local SOCKETS = { "socketsKnown" }
local ABSENT = { "absent" }

-- A finding that cannot be verified is "unknown", not silence. Silence produces
-- no finding, and no finding renders as a green cell -- a verified pass drawn
-- from evidence we do not have. This is the same rule as stateFor, applied to
-- the case where the obstacle is our own data rather than the player's.
local function unverified(findings, slot, kind, what)
  add(findings, slot, kind, "warn", "unknown",
      what .. " data is out of date for this client build")
end

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

-- Takes the item rather than its parse result, because whether an off-hand is
-- enchantable at all depends on its item class, which is not in the link.
local function checkEnchant(findings, slot, item, slotRecord, context)
  if not ns.Policy.Slots.isEnchantable(slot, item.classID) then return end

  local parsed = item.parsed
  if parsed.enchantID == 0 then
    add(findings, slot, "missing_enchant", "error",
        stateFor(slotRecord, LINK, context),
        "no enchant on an enchantable slot")
    return
  end

  -- Out-of-date tables cannot rank an enchant, but they can still see one is
  -- there. Say so rather than returning: an unrankable enchant is unknown.
  if not context.dataValid then
    unverified(findings, slot, "enchant_unverified", "enchant")
    return
  end

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
  for i = 1, 4 do
    local gemID = parsed.gemIDs[i]
    if gemID ~= 0 then
      -- Reported once per slot, not once per gem: the obstacle is the same
      -- table for all four, and four identical lines say nothing extra.
      if not context.dataValid then
        unverified(findings, slot, "gem_unverified", "gem")
        return
      end
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
    -- Confirmed by absence reads, not by itemLoaded: there is no item here to
    -- load, so itemLoaded could never arrive and this finding could never leave
    -- the unknown state. Whether an empty off-hand is legitimate is decided one
    -- level up, where the main hand is visible.
    add(findings, slot, "missing_item", "error",
        stateFor(slotRecord, ABSENT, context),
        "no item in this slot")
    return findings
  end

  checkEnchant(findings, slot, item, slotRecord, context)
  checkGems(findings, slot, item.parsed, slotRecord, context)
  checkUpgrade(findings, slot, item.upgrade, slotRecord, context)
  checkSockets(findings, slot, item, slotRecord, context)

  return findings
end

-- Tier and embellishments are the first checks that cannot be judged per slot:
-- you can only say how many tier pieces someone wears once all five slots are
-- in. Counts what is worn, not what is enough -- the threshold is Season's to
-- decide, and it is four rather than five.
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
  return worn
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

-- A total is only as trustworthy as its weakest contributor, so one unconfirmed
-- slot makes the whole count unknown. These two findings used to hardcode "bad"
-- and were the only ones in the file that could go red without the evidence rule
-- the rest of it enforces.
local function entryConfirmed(entry, context)
  if not entry then return false end
  local sources = entry.parsed and LINK or ABSENT
  return ns.Evidence.isConfirmed(entry.record, sources, context.minInterval)
end

local function tierConfirmed(slots, context)
  local tierSlots = ns.Policy.Slots.TIER
  for i = 1, table.getn(tierSlots) do
    if not entryConfirmed(slots[tierSlots[i]], context) then return false end
  end
  return true
end

-- The tier count as numbers rather than as a sentence, for the grid's column.
-- Both the column and the warning below read this, because a column that says
-- 4/4 beside a warning that says otherwise is worse than having neither.
--
-- Nil means the question cannot be answered rather than that the answer is zero:
-- without trustworthy set IDs a fully tiered raider counts as wearing none, and
-- an empty column is honest where a wrong number is not.
function Rules.tierStatus(slots, context)
  if not context.dataValid then return nil end

  local worn = countTierPieces(slots)
  if not worn then return nil end

  return {
    worn = worn,
    required = ns.Policy.Season.TIER_PIECES_REQUIRED,
    confirmed = tierConfirmed(slots, context),
  }
end

-- Embellishments are counted over every slot that has an item, so every one of
-- those has to be confirmed -- unlike tier, which only reads five known slots.
local function countedSlotsConfirmed(slots, context)
  for _, entry in pairs(slots) do
    if not entryConfirmed(entry, context) then return false end
  end
  return true
end

-- What an empty off-hand means depends on the main hand, which only the
-- player-wide pass can see. Three answers, not two: if the main hand's equip
-- location could not be read we cannot tell a greatsword from a one-hander, and
-- guessing either way is how a correctly geared warrior gets a red slot or a
-- genuinely naked one gets a pass.
local function emptyOffHandVerdict(slots)
  local mainHand = slots[ns.Policy.Slots.MAINHAND]
  if not mainHand or not mainHand.parsed then return "report" end
  if not mainHand.equipLoc then return "unknown" end
  if ns.Policy.Slots.occupiesBothHands(mainHand.equipLoc) then return "expected" end
  return "report"
end

local function slotFindingsFor(slot, entry, slots, context)
  if slot ~= ns.Policy.Slots.OFFHAND or entry.parsed then
    return Rules.evaluateSlot(slot, entry, entry.record, context)
  end

  local verdict = emptyOffHandVerdict(slots)
  if verdict == "expected" then return {} end

  local findings = Rules.evaluateSlot(slot, entry, entry.record, context)
  if verdict == "unknown" then
    for i = 1, table.getn(findings) do findings[i].state = "unknown" end
  end
  return findings
end

function Rules.evaluatePlayer(slots, context)
  local findings = {}

  for slot, entry in pairs(slots) do
    local slotFindings = slotFindingsFor(slot, entry, slots, context)
    for i = 1, table.getn(slotFindings) do
      findings[table.getn(findings) + 1] = slotFindings[i]
    end
  end

  -- Tier depends on generated set IDs, so stale data makes the count meaningless
  -- rather than merely unranked: last season's IDs match nobody and a fully
  -- tiered raider reads as 0 of 5. Report the obstacle instead of the count.
  if not context.dataValid then
    unverified(findings, nil, "tier_unverified", "tier set")
  else
    local tier = Rules.tierStatus(slots, context)
    if tier and tier.worn < tier.required then
      add(findings, nil, "tier_incomplete", "warn",
          tier.confirmed and "bad" or "unknown",
          tier.worn .. " of " .. tier.required .. " tier pieces")
    end
  end

  -- Embellishments are read off the tooltip, not out of a generated table, so
  -- they survive a data version this addon does not recognise.
  local embellishments = countEmbellishments(slots)
  local maxEmbellishments = ns.Policy.Season.MAX_EMBELLISHMENTS
  if embellishments and embellishments < maxEmbellishments then
    add(findings, nil, "embellishments_missing", "warn",
        countedSlotsConfirmed(slots, context) and "bad" or "unknown",
        embellishments .. " of " .. maxEmbellishments .. " embellishments")
  end

  return findings
end
