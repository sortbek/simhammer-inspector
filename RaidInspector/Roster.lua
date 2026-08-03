local addonName, ns = ...

local Roster = {}
ns.Roster = Roster

local members = {}
local listeners = { added = {}, removed = {} }

local function notify(kind, guid, info)
  for i = 1, table.getn(listeners[kind]) do
    listeners[kind][i](guid, info)
  end
end

function Roster.onAdded(fn) listeners.added[table.getn(listeners.added) + 1] = fn end
function Roster.onRemoved(fn) listeners.removed[table.getn(listeners.removed) + 1] = fn end

function Roster.get(guid) return members[guid] end
function Roster.all() return members end

function Roster.count()
  local n = 0
  for _ in pairs(members) do n = n + 1 end
  return n
end

-- Unit tokens shift as people join and leave, so the token is refreshed on every
-- roster update and never cached beyond it. The GUID is the stable identity.
local function unitTokens()
  local tokens = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      tokens[table.getn(tokens) + 1] = "raid" .. i
    end
  elseif IsInGroup() then
    tokens[table.getn(tokens) + 1] = "player"
    for i = 1, GetNumGroupMembers() - 1 do
      tokens[table.getn(tokens) + 1] = "party" .. i
    end
  else
    tokens[table.getn(tokens) + 1] = "player"
  end
  return tokens
end

function Roster.refresh()
  local seen = {}
  local tokens = unitTokens()

  for i = 1, table.getn(tokens) do
    local unit = tokens[i]
    local guid = UnitGUID(unit)
    if guid and UnitIsPlayer(unit) then
      seen[guid] = true
      local _, class = UnitClass(unit)
      local name, realm = UnitName(unit)
      local info = members[guid]
      if not info then
        info = { guid = guid }
        members[guid] = info
        info.name, info.realm, info.class, info.unit = name, realm, class, unit
        notify("added", guid, info)
      else
        info.name, info.realm, info.class, info.unit = name, realm, class, unit
      end
    end
  end

  for guid in pairs(members) do
    if not seen[guid] then
      local info = members[guid]
      members[guid] = nil
      notify("removed", guid, info)
    end
  end
end
