local addonName, ns = ...

ns.Policy = ns.Policy or {}
local Season = {}
ns.Policy.Season = Season

-- Which tier counts as "current". Data/Enchants.lua and Data/Gems.lua hold the
-- full history with a tier tag; this file decides which part of it is current.
-- That way a known but outdated ID produces a warning instead of "unknown", and
-- unknown stays reserved for what genuinely is not recognised.
Season.CURRENT_TIER = "midnight-s1"

Season.MAX_EMBELLISHMENTS = 2

-- Points at the generated table rather than restating it. Which sets are the
-- current tier turned out to be derivable -- five-piece sets in the current item
-- ID block -- so hand-copying thirteen IDs would only introduce a second source
-- to drift out of step. There is still exactly one authority.
Season.TIER_SET_IDS = ns.Data and ns.Data.TierSets or {}
