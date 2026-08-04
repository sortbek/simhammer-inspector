local addonName, ns = ...

ns.Data = ns.Data or {}

-- Specialisation ID to name, for the spec= line of a SimC profile. Taken from
-- the SimulationCraft addon's own table rather than from GetSpecializationInfo,
-- because SimC matches on these exact names and a localised client would return
-- something it does not recognise.
ns.Data.SpecNames = {
  -- Death Knight
  [250] = "Blood", [251] = "Frost", [252] = "Unholy",
  -- Demon Hunter
  [577] = "Havoc", [581] = "Vengeance", [1480] = "Devourer",
  -- Druid
  [102] = "Balance", [103] = "Feral", [104] = "Guardian", [105] = "Restoration",
  -- Evoker
  [1473] = "Augmentation", [1467] = "Devastation", [1468] = "Preservation",
  -- Hunter
  [253] = "Beast Mastery", [254] = "Marksmanship", [255] = "Survival",
  -- Mage
  [62] = "Arcane", [63] = "Fire", [64] = "Frost",
  -- Monk
  [268] = "Brewmaster", [269] = "Windwalker", [270] = "Mistweaver",
  -- Paladin
  [65] = "Holy", [66] = "Protection", [70] = "Retribution",
  -- Priest
  [256] = "Discipline", [257] = "Holy", [258] = "Shadow",
  -- Rogue
  [259] = "Assassination", [260] = "Outlaw", [261] = "Subtlety",
  -- Shaman
  [262] = "Elemental", [263] = "Enhancement", [264] = "Restoration",
  -- Warlock
  [265] = "Affliction", [266] = "Demonology", [267] = "Destruction",
  -- Warrior
  [71] = "Arms", [72] = "Fury", [73] = "Protection",
}
