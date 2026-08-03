-- Real tooltip lines from the spike. formatString is the value
-- ITEM_UPGRADE_TOOLTIP_FORMAT_STRING returned in game on 12.0.7.

return {
  formatString = "Upgrade Level: %s %d/%d",

  withTrack = {
    "Upgrade Level: Myth 6/6",
    "Upgrade Level: Myth 5/6",
    "Upgrade Level: Myth 3/6",
    "Upgrade Level: Myth 2/6",
    "Upgrade Level: Myth 1/6",
    "Upgrade Level: Hero 6/6",
    "Upgrade Level: Hero 3/6",
  },

  -- A real trinket tooltip with no upgrade line. 78 of 184 items looked like
  -- this, so absence is not evidence of "fully upgraded".
  withoutTrack = {
    "Gaze of the Alnseer",
    "Item Level 298",
    "Binds when picked up",
    "Unique-Equipped",
    "Trinket",
    "+123 Mastery",
    "+55 Avoidance",
  },

  -- A real bracer tooltip with a socket and an embellishment.
  socketedCrafted = {
    "Silvermoon Agent's Deflectors",
    "Radiance Crafted",
    "Item Level 285",
    "Binds when picked up",
    "Unique-Equipped: Embellished (2)",
    "Wrist",
    "72 Armor",
    "+67 Intellect",
    "Prismatic Socket",
  },
}
