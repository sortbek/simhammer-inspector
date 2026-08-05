local addonName, ns = ...

local DataVersion = {}
ns.DataVersion = DataVersion

local function parts(version)
  if type(version) ~= "string" then return nil end
  local major, minor, patch = string.match(version, "^(%d+)%.(%d+)%.(%d+)$")
  if not major then return nil end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

-- Degradation keys off the patch version, not the build number. Build numbers
-- rise almost weekly through hotfixes that touch no items; degrading on build
-- would put the addon in a crippled state for most of every season, the exact
-- opposite of what this safeguard is for.
function DataVersion.compare(dataVersion, gameVersion)
  local a = parts(dataVersion and dataVersion.version)
  local b = parts(gameVersion and gameVersion.version)

  -- Unparseable is not the same as equal. Staying silent beats guessing.
  if not a or not b then return "newer-patch" end

  for i = 1, 3 do
    if b[i] > a[i] then return "newer-patch" end
    if b[i] < a[i] then return "current" end
  end

  local dataBuild = tonumber(dataVersion.build) or 0
  local gameBuild = tonumber(gameVersion.build) or 0
  if gameBuild > dataBuild then return "newer-build" end

  return "current"
end

function DataVersion.isValid(status)
  return status ~= "newer-patch"
end
