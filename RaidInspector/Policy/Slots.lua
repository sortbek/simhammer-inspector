local addonName, ns = ...

ns.Policy = ns.Policy or {}
local Slots = {}
ns.Policy.Slots = Slots

-- WoW inventarisslot-nummers. Bewust letterlijk en niet via INVSLOT_-globals,
-- zodat dit bestand buiten de game te laden en te testen is.
local HEAD, NECK, SHOULDER        = 1, 2, 3
local CHEST, WAIST, LEGS, FEET    = 5, 6, 7, 8
local WRIST, HANDS, FINGER1       = 9, 10, 11
local FINGER2, TRINKET1, TRINKET2 = 12, 13, 14
local BACK, MAINHAND, OFFHAND     = 15, 16, 17

Slots.ALL = {
  HEAD, NECK, SHOULDER, BACK, CHEST, WRIST, HANDS, WAIST,
  LEGS, FEET, FINGER1, FINGER2, TRINKET1, TRINKET2, MAINHAND, OFFHAND,
}

Slots.TIER = { HEAD, SHOULDER, CHEST, HANDS, LEGS }

-- Midnight seizoen 1: cloak en bracers zijn eruit, helm en shoulders terug.
-- Benen dragen een spellthread, die in hetzelfde enchantID-veld terechtkomt.
local ENCHANTABLE = {
  [HEAD] = true, [SHOULDER] = true, [CHEST] = true, [LEGS] = true,
  [FEET] = true, [FINGER1] = true, [FINGER2] = true, [MAINHAND] = true,
}

-- Items die een socket kunnen krijgen via een los te kopen item.
local SOCKETABLE = { [HEAD] = true, [WRIST] = true, [WAIST] = true }

function Slots.isEnchantable(slot, itemSubclass)
  if slot == OFFHAND then
    return itemSubclass == "weapon"
  end
  return ENCHANTABLE[slot] == true
end

function Slots.isSocketable(slot)
  return SOCKETABLE[slot] == true
end
