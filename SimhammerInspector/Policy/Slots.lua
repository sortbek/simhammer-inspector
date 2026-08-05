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

-- The canonical slot order. Every consumer reads this rather than restating it:
-- the order is load-bearing, because SimcExport maps it onto SimC slot keys, and
-- four independent copies were four chances to reorder one and silently export
-- trinkets as rings.
Slots.ALL = {
  HEAD, NECK, SHOULDER, BACK, CHEST, WRIST, HANDS, WAIST,
  LEGS, FEET, FINGER1, FINGER2, TRINKET1, TRINKET2, MAINHAND, OFFHAND,
}

-- Display names, kept beside the order so the grid, the detail panel and the
-- chat report cannot disagree about what slot 9 is called. Pure string data, so
-- it does not compromise this file's "loadable outside the game" property.
Slots.NAMES = {
  [HEAD] = "Head", [NECK] = "Neck", [SHOULDER] = "Shoulders", [BACK] = "Back",
  [CHEST] = "Chest", [WRIST] = "Wrist", [HANDS] = "Hands", [WAIST] = "Waist",
  [LEGS] = "Legs", [FEET] = "Feet", [FINGER1] = "Finger 1", [FINGER2] = "Finger 2",
  [TRINKET1] = "Trinket 1", [TRINKET2] = "Trinket 2",
  [MAINHAND] = "Main Hand", [OFFHAND] = "Off Hand",
}

-- SimC slot keys, keyed by slot number rather than by position. The previous
-- shape was a parallel array indexed against ALL, so reordering ALL reassigned
-- every item line without any test able to notice.
Slots.SIMC = {
  [HEAD] = "head", [NECK] = "neck", [SHOULDER] = "shoulder", [BACK] = "back",
  [CHEST] = "chest", [WRIST] = "wrist", [HANDS] = "hands", [WAIST] = "waist",
  [LEGS] = "legs", [FEET] = "feet", [FINGER1] = "finger1", [FINGER2] = "finger2",
  [TRINKET1] = "trinket1", [TRINKET2] = "trinket2",
  [MAINHAND] = "main_hand", [OFFHAND] = "off_hand",
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
