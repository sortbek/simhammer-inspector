local addonName, ns = ...

ns.Data = ns.Data or {}

-- GEGENEREERD in deel 2 uit wago.tools. Deze stub bevat alleen genoeg entries
-- om de regels te kunnen testen. Vorm: enchantID -> { quality, tier }.
-- quality is "silver" of "gold"; tier is de seizoenstag.
ns.Data.Enchants = {
  [7364] = { quality = "gold",   tier = "midnight-s1" },
  [7361] = { quality = "silver", tier = "midnight-s1" },
  [6625] = { quality = "gold",   tier = "tww-s4" },
}
