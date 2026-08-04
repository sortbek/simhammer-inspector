local addonName, ns = ...

local Adapter = {}
ns.UpgradeTrackAdapter = Adapter

-- Tooltip parsing lives apart from the Hydrator on purpose: it is locale and
-- build sensitive and has its own failure path. A line that is not there means
-- UNKNOWN, never "no upgrades remaining" -- 78 of the 184 items in the spike had
-- no upgrade line, and they are not all fully upgraded.

local MAGIC = "([%^%$%(%)%%%.%[%]%*%+%-%?])"

local function escape(s)
  return (string.gsub(s, MAGIC, "%%%1"))
end

-- Turns "Upgrade Level: %s %d/%d" into "^Upgrade Level: (.-) (%d+)/(%d+)$".
-- The pattern comes from Blizzard's own global string so it is still correct on
-- a German or French client.
function Adapter.buildPattern(formatString)
  if type(formatString) ~= "string" then return nil end

  local parts, n = {}, 0
  local index = 1

  while true do
    local first, last, spec = string.find(formatString, "%%([sd])", index)
    if not first then break end
    n = n + 1
    parts[n] = escape(string.sub(formatString, index, first - 1))
    n = n + 1
    -- Lazy capture for the track name: it can contain spaces, and the anchored
    -- tail forces backtracking to the right split.
    parts[n] = (spec == "s") and "(.-)" or "(%d+)"
    index = last + 1
  end

  n = n + 1
  parts[n] = escape(string.sub(formatString, index))

  return "^" .. table.concat(parts) .. "$"
end

function Adapter.parse(tooltipLines, pattern)
  if type(tooltipLines) ~= "table" or type(pattern) ~= "string" then return nil end

  for i = 1, table.getn(tooltipLines) do
    local line = tooltipLines[i]
    if type(line) == "string" then
      local track, rank, max = string.match(line, pattern)
      if track then
        return { track = track, rank = tonumber(rank), max = tonumber(max) }
      end
    end
  end

  return nil
end
