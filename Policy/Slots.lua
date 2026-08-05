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

-- The two weapon slots are named because Rules has to relate them to each other,
-- and "slot == 17" at a call site is a number nobody can check.
Slots.MAINHAND = MAINHAND
Slots.OFFHAND = OFFHAND

-- How many of the sixteen slots an inspect must return before the pass counts as
-- a complete read of the character, which is what absence findings are concluded
-- from. A raider fills every slot: sixteen normally, fifteen with a two-hander.
-- So the realistic fault -- a forgotten ring or trinket -- returns fifteen or
-- fourteen, and fourteen is the floor that still catches it.
--
-- Deliberately not the queue's substantialPassSlots, though the two started out
-- sharing a number. They answer different questions: the queue asks whether it
-- learned enough to count the pass as progress, this asks whether the pass saw
-- the whole character well enough to call a slot empty. The second is the
-- stricter question, because being wrong means accusing someone.
Slots.MIN_COMPLETE_PASS = 14

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

-- LE_ITEM_CLASS_WEAPON. Written out rather than taken from the global for the
-- same reason as the slot numbers, and matched numerically rather than against
-- the item type string: that string is localised, so comparing it to "weapon"
-- silently classifies every weapon on a non-English client as not-a-weapon.
Slots.WEAPON_CLASS_ID = 2

-- Equip locations that occupy both hands, which makes an empty off-hand correct
-- rather than a finding. Ranged weapons belong here too: a hunter's bow sits in
-- the main hand and leaves the off-hand legitimately empty.
local BOTH_HANDS = {
  INVTYPE_2HWEAPON = true, INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true,
}

-- itemClassID is only consulted for the off-hand, where it is the difference
-- between a weapon (enchantable) and a shield or held-in-off-hand item (not).
function Slots.isEnchantable(slot, itemClassID)
  if slot == OFFHAND then
    return itemClassID == Slots.WEAPON_CLASS_ID
  end
  return ENCHANTABLE[slot] == true
end

function Slots.occupiesBothHands(equipLoc)
  return BOTH_HANDS[equipLoc] == true
end

function Slots.isSocketable(slot)
  return SOCKETABLE[slot] == true
end
