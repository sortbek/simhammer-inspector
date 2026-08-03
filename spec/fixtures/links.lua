-- Itemlink-structuur (retail):
--   item:itemID:enchantID:gem1:gem2:gem3:gem4:suffixID:uniqueID:linkLevel
--       :specID:modifiersMask:itemContext:numBonusIDs:bonus...:numModifiers
--       :modType1:modValue1:...
--
-- LET OP: deze fixtures zijn SYNTHETISCH. Ze zijn structureel correct maar de
-- ID's zijn verzonnen. Taak 4 vervangt ze door echte links uit Midnight.

return {
  -- Ring met enchant en één gem, drie bonus-ID's, één modifier-paar.
  ringWithEnchantAndGem =
    "|cffa335ee|Hitem:211018:7364:213743::::::80:268:0:6:3:10421:9633:8902:1:28:2462|h[Testring]|h|r",

  -- Chest zonder enchant en zonder gems, één bonus-ID, geen modifiers.
  chestBare =
    "|cffa335ee|Hitem:212446::::::::80:268::11:1:10356:0|h[Testborst]|h|r",

  -- Kaal item: alleen een itemID, alle overige velden leeg.
  minimal =
    "|cffffffff|Hitem:6948::::::::80:268::::|h[Hearthstone]|h|r",

  -- Alleen het item-gedeelte, zonder kleurcode of naam.
  plainPayload =
    "item:211018:7364:213743::::::80:268:0:6:3:10421:9633:8902:1:28:2462",

  notAnItem =
    "|cff71d5ff|Hspell:12345|h[Een spreuk]|h|r",
}
