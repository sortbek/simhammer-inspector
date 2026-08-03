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

local function checkEnchant(findings, slot, parsed, slotRecord, context)
  if not ns.Policy.Slots.isEnchantable(slot, context.itemSubclass) then return end

  if parsed.enchantID == 0 then
    add(findings, slot, "missing_enchant", "error",
        stateFor(slotRecord, { "linkComplete" }, context),
        "no enchant on an enchantable slot")
    return
  end

  if not context.dataValid then return end

  local info = ns.Data.Enchants[parsed.enchantID]
  if not info then return end

  if info.tier ~= ns.Policy.Season.CURRENT_TIER then
    add(findings, slot, "outdated_enchant", "warn",
        stateFor(slotRecord, { "linkComplete" }, context),
        "enchant from " .. info.tier)
  elseif info.quality ~= "gold" then
    add(findings, slot, "low_enchant", "warn",
        stateFor(slotRecord, { "linkComplete" }, context),
        "enchant is " .. info.quality .. " instead of gold")
  end
end

local function checkGems(findings, slot, parsed, slotRecord, context)
  if not context.dataValid then return end

  for i = 1, 4 do
    local gemID = parsed.gemIDs[i]
    if gemID ~= 0 then
      local info = ns.Data.Gems[gemID]
      if info then
        if info.tier ~= ns.Policy.Season.CURRENT_TIER then
          add(findings, slot, "outdated_gem", "warn",
              stateFor(slotRecord, { "linkComplete" }, context),
              "gem from " .. info.tier)
        elseif info.quality ~= "gold" then
          add(findings, slot, "low_gem", "warn",
              stateFor(slotRecord, { "linkComplete" }, context),
              "gem is " .. info.quality .. " instead of gold")
        end
      end
    end
  end
end

function Rules.evaluateSlot(slot, parsed, slotRecord, context)
  local findings = {}

  if not parsed then
    -- A two-handed weapon makes an empty off-hand correct, not a finding.
    local isEmptyOffhandWithTwoHander = (slot == 17 and context.twoHanded)
    if not isEmptyOffhandWithTwoHander then
      add(findings, slot, "missing_item", "error",
          stateFor(slotRecord, { "itemLoaded" }, context),
          "no item in this slot")
    end
    return findings
  end

  checkEnchant(findings, slot, parsed, slotRecord, context)
  checkGems(findings, slot, parsed, slotRecord, context)

  return findings
end

-- Tier and embellishments are the first checks that cannot be judged per slot:
-- you can only say someone wears 3 of 5 tier pieces once all five slots are in.
local function countTierPieces(slots)
  local setIDs = ns.Policy.Season.TIER_SET_IDS
  local known = false
  for _ in pairs(setIDs) do known = true; break end
  if not known then return nil end

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

local function countEmbellishments(slots)
  local found = 0
  for _, entry in pairs(slots) do
    if entry.parsed and entry.parsed.bonusIDs then
      for i = 1, table.getn(entry.parsed.bonusIDs) do
        if ns.Data.Embellishments[entry.parsed.bonusIDs[i]] then
          found = found + 1
        end
      end
    end
  end
  return found
end

function Rules.evaluatePlayer(slots, context)
  local findings = {}

  for slot, entry in pairs(slots) do
    local slotFindings = Rules.evaluateSlot(slot, entry.parsed, entry.record, context)
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
  if embellishments < maxEmbellishments then
    add(findings, nil, "embellishments_missing", "warn", "bad",
        embellishments .. " of " .. maxEmbellishments .. " embellishments")
  end

  return findings
end
