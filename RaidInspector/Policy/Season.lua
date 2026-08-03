local addonName, ns = ...

ns.Policy = ns.Policy or {}
local Season = {}
ns.Policy.Season = Season

-- Welke tier als "actueel" telt. Data/Enchants.lua en Data/Gems.lua bevatten de
-- volledige historie met een tier-tag; dit bestand bepaalt wat daarvan actueel
-- is. Zo levert een bekende maar verouderde ID een waarschuwing op in plaats
-- van "onbekend", en blijft onbekend gereserveerd voor wat echt niet herkend is.
Season.CURRENT_TIER = "midnight-s1"

Season.MAX_EMBELLISHMENTS = 2

-- Enige plek waar de actuele tier-setIDs staan. Bewust niet ook in Data/,
-- want twee bronnen voor hetzelfde feit lopen gegarandeerd uiteen.
-- Vul in met de setID's uit de spike; de lege tabel houdt de tier-check
-- inactief zonder foute meldingen te produceren.
Season.TIER_SET_IDS = {}
