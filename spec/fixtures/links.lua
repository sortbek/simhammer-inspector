-- Item link structure (retail):
--   item:itemID:enchantID:gem1:gem2:gem3:gem4:suffixID:uniqueID:linkLevel
--       :specID:modifiersMask:itemContext:numBonusIDs:bonus...:numModifiers
--       :modType1:modValue1:...:<crafter GUID and relic sections>
--
-- These links come from real inspects on Midnight 12.0.7, build 68887, captured
-- with the spike addon. Regenerate with tools/extract-fixtures.lua.
--
-- Three things the real data revealed that you would not have guessed:
--   * the colour prefix is |cnIQ4: and no longer |cffa335ee
--   * modifier values can be negative (-2147480301 is common)
--   * a non-numeric field can follow the modifiers (the crafter GUID)

return {
  -- Ring: enchant 7967, one gem, four bonus IDs, no modifiers.
  ringWithEnchantAndGem =
    "|cnIQ4:|Hitem:268290:7967:240890::::::90:270::6:4:6652:13668:13335:13786::::::|h[Sporecaller's Blooming Loop]|h|r",

  -- Crafted and embellished bracer: nine bonus IDs, ten modifier pairs
  -- including a negative value. This is the item naive parsing breaks on.
  craftedEmbellished =
    "|cnIQ4:|Hitem:244576::240908::::::90:270::13:9:12214:13667:12497:12066:8960:12384:8791:13622:12666:10:28:3615:29:49:30:32:38:8:40:4006:47:232875:48:240167:49:245790:50:-2147480301:51:246212:::::|h[Silvermoon Agent's Deflectors]|h|r",

  -- Weapon with enchant 8039, nine modifier pairs, and a crafter GUID as a
  -- non-numeric field behind the modifiers.
  weaponEnchanted =
    "|cnIQ4:|Hitem:245770:8039:::::::90:270::13:8:12214:13655:12497:12066:13640:8960:8790:13622:9:28:3615:29:49:30:40:38:8:40:2907:45:232875:46:245874:47:245786:48:-2147480301::::Player-1403-0B343557:|h[Aln'hara Cane]|h|r",

  -- Trinket without enchant or gems, three bonus IDs, no modifiers.
  bareNoEnchantNoGem =
    "|cnIQ4:|Hitem:249343::::::::90:270::6:3:40:13335:13654::::::|h[Gaze of the Alnseer]|h|r",

  -- Upgraded item with enchant and gem, five bonus IDs.
  upgradedItem =
    "|cnIQ4:|Hitem:251217:7967:240890::::::90:270::35:5:13440:41:13668:12699:12806::::::|h[Occlusion of Void]|h|r",

  -- Held-in-off-hand frill: no enchant, four bonus IDs, one modifier pair.
  -- Confirms that an off-hand which is not a weapon should carry no enchant.
  heldInOffhand =
    "|cnIQ4:|Hitem:193709::::::::90:270::16:4:12795:13440:6652:12699:1:28:1279:::::|h[Vexamus' Expulsion Rod]|h|r",

  -- SYNTHETIC: edge cases absent from the spike data that the parser must
  -- still survive.
  minimal =
    "|cffffffff|Hitem:6948::::::::90:270::::|h[Hearthstone]|h|r",

  plainPayload =
    "item:268290:7967:240890::::::90:270::6:4:6652:13668:13335:13786::::::",

  notAnItem =
    "|cff71d5ff|Hspell:12345|h[A spell]|h|r",
}
