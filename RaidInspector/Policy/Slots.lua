local addonName, ns = ...

ns.Policy = ns.Policy or {}
local Slots = {}
ns.Policy.Slots = Slots

-- WoW inventory slot numbers, written out literally rather than taken from the
-- INVSLOT_ globals so this file can be loaded and tested outside the game.
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

-- Midnight season 1: cloak and bracers dropped out, helm and shoulders came
-- back. Legs carry a spellthread, which lands in the same enchantID field.
-- Confirmed against real inspect data: cloak, bracers, neck, waist, hands and
-- trinkets showed zero enchants across 33 observations.
local ENCHANTABLE = {
  [HEAD] = true, [SHOULDER] = true, [CHEST] = true, [LEGS] = true,
  [FEET] = true, [FINGER1] = true, [FINGER2] = true, [MAINHAND] = true,
}

-- Slots that can gain a socket from a separately purchased item.
local SOCKETABLE = { [HEAD] = true, [WRIST] = true, [WAIST] = true }

function Slots.isEnchantable(slot, itemSubclass)
  -- Only an off-hand *weapon* takes an enchant; shields and held-in-off-hand
  -- frills do not.
  if slot == OFFHAND then
    return itemSubclass == "weapon"
  end
  return ENCHANTABLE[slot] == true
end

function Slots.isSocketable(slot)
  return SOCKETABLE[slot] == true
end
