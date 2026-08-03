-- Itemlink-structuur (retail):
--   item:itemID:enchantID:gem1:gem2:gem3:gem4:suffixID:uniqueID:linkLevel
--       :specID:modifiersMask:itemContext:numBonusIDs:bonus...:numModifiers
--       :modType1:modValue1:...:<crafter-GUID en relic-secties>
--
-- Deze links komen uit echte inspects op Midnight 12.0.7, build 68887, via de
-- spike-addon. Regenereren kan met tools/extract-fixtures.lua.
--
-- Drie dingen die uit deze echte data bleken en die je niet verzint:
--   * het kleurvoorvoegsel is |cnIQ4: en niet meer |cffa335ee
--   * modifier-waarden kunnen negatief zijn (-2147480301 komt vaak voor)
--   * achter de modifiers kan een niet-numeriek veld staan (de crafter-GUID)

return {
  -- Ring: enchant 7967, één gem, vier bonus-IDs, geen modifiers.
  ringWithEnchantAndGem =
    "|cnIQ4:|Hitem:268290:7967:240890::::::90:270::6:4:6652:13668:13335:13786::::::|h[Sporecaller's Blooming Loop]|h|r",

  -- Crafted en embellished bracer: negen bonus-IDs, tien modifier-paren
  -- waaronder een negatieve waarde. Dit is het item waar naïef parsen op breekt.
  craftedEmbellished =
    "|cnIQ4:|Hitem:244576::240908::::::90:270::13:9:12214:13667:12497:12066:8960:12384:8791:13622:12666:10:28:3615:29:49:30:32:38:8:40:4006:47:232875:48:240167:49:245790:50:-2147480301:51:246212:::::|h[Silvermoon Agent's Deflectors]|h|r",

  -- Wapen met enchant 8039, negen modifier-paren, en een crafter-GUID als
  -- niet-numeriek veld achter de modifiers.
  weaponEnchanted =
    "|cnIQ4:|Hitem:245770:8039:::::::90:270::13:8:12214:13655:12497:12066:13640:8960:8790:13622:9:28:3615:29:49:30:40:38:8:40:2907:45:232875:46:245874:47:245786:48:-2147480301::::Player-1403-0B343557:|h[Aln'hara Cane]|h|r",

  -- Trinket zonder enchant en zonder gems, drie bonus-IDs, geen modifiers.
  bareNoEnchantNoGem =
    "|cnIQ4:|Hitem:249343::::::::90:270::6:3:40:13335:13654::::::|h[Gaze of the Alnseer]|h|r",

  -- Geupgraded item met enchant en gem, vijf bonus-IDs.
  upgradedItem =
    "|cnIQ4:|Hitem:251217:7967:240890::::::90:270::35:5:13440:41:13668:12699:12806::::::|h[Occlusion of Void]|h|r",

  -- Held-in-off-hand frill: geen enchant, vier bonus-IDs, een modifier-paar.
  -- Bevestigt dat een off-hand die geen wapen is geen enchant hoort te hebben.
  heldInOffhand =
    "|cnIQ4:|Hitem:193709::::::::90:270::16:4:12795:13440:6652:12699:1:28:1279:::::|h[Vexamus' Expulsion Rod]|h|r",

  -- SYNTHETISCH: randgevallen die niet in de spike-data voorkwamen maar die de
  -- parser wel moet overleven.
  minimal =
    "|cffffffff|Hitem:6948::::::::90:270::::|h[Hearthstone]|h|r",

  plainPayload =
    "item:268290:7967:240890::::::90:270::6:4:6652:13668:13335:13786::::::",

  notAnItem =
    "|cff71d5ff|Hspell:12345|h[Een spreuk]|h|r",
}
