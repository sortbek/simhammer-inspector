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

-- The only place the current tier set IDs live. Deliberately not in Data/ as
-- well, because two sources for the same fact are guaranteed to drift apart.
-- Fill in with the set IDs from the spike; the empty table keeps the tier check
-- inactive rather than producing wrong findings.
Season.TIER_SET_IDS = {}
