local addonName, ns = ...

local Rules = {}
ns.Rules = Rules

local function add(findings, slot, kind, severity, state, detail)
  findings[table.getn(findings) + 1] = {
    slot = slot, kind = kind, severity = severity,
    state = state, detail = detail,
  }
end

-- Negatieve bevindingen mogen pas "bad" worden als het bewijs er is; tot die
-- tijd zijn ze "unknown". Dit is de kern van sectie 6 van de spec: een rood
-- vakje op grond van data die nog niet binnen was, is erger dan geen data.
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
        "geen enchant op een enchantbaar slot")
    return
  end

  if not context.dataValid then return end

  local info = ns.Data.Enchants[parsed.enchantID]
  if not info then return end

  if info.tier ~= ns.Policy.Season.CURRENT_TIER then
    add(findings, slot, "outdated_enchant", "warn",
        stateFor(slotRecord, { "linkComplete" }, context),
        "enchant uit " .. info.tier)
  elseif info.quality ~= "gold" then
    add(findings, slot, "low_enchant", "warn",
        stateFor(slotRecord, { "linkComplete" }, context),
        "enchant is " .. info.quality .. " in plaats van gold")
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
              "gem uit " .. info.tier)
        elseif info.quality ~= "gold" then
          add(findings, slot, "low_gem", "warn",
              stateFor(slotRecord, { "linkComplete" }, context),
              "gem is " .. info.quality .. " in plaats van gold")
        end
      end
    end
  end
end

function Rules.evaluateSlot(slot, parsed, slotRecord, context)
  local findings = {}

  if not parsed then
    local isEmptyOffhandWithTwoHander = (slot == 17 and context.twoHanded)
    if not isEmptyOffhandWithTwoHander then
      add(findings, slot, "missing_item", "error",
          stateFor(slotRecord, { "itemLoaded" }, context),
          "geen item in dit slot")
    end
    return findings
  end

  checkEnchant(findings, slot, parsed, slotRecord, context)
  checkGems(findings, slot, parsed, slotRecord, context)

  return findings
end
