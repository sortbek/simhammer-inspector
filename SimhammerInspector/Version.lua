local addonName, ns = ...

-- The git tag is the only version number. The packager writes it into the TOC
-- when it builds the zip, and this reads it back rather than keeping a second
-- copy here to go stale the first time a release is tagged and this file is not
-- touched.
--
-- Exposed rather than inlined so the two answers that are not a version -- the
-- unsubstituted token and no TOC at all -- can be tested without a client.
function ns.readVersion(raw)
  if not raw or raw == "" then return "dev" end
  -- Matched as a pattern, which is not the literal token, so the packager does
  -- not helpfully substitute this line as well.
  if string.find(raw, "project%-version") then return "dev" end
  return raw
end

-- C_AddOns since 11.0; the bare global stays as a fallback for the same reason
-- the rest of the addon guards its API calls. Both being absent is what running
-- outside the game looks like, and that answers "dev" like any other build that
-- has not been packaged.
local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

ns.VERSION = ns.readVersion(getMetadata and getMetadata(addonName, "Version"))
