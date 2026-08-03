local addonName, ns = ...

local Cache = {}
ns.Cache = Cache

local Instance = {}
Instance.__index = Instance

-- The store is passed in rather than reached for, so the tests can hand over a
-- plain table where the addon hands over its SavedVariables.
function Cache.new(store, config)
  store.players = store.players or {}
  return setmetatable({ store = store, config = config }, Instance)
end

-- Only raw data belongs in here. Derived values are recomputed on load, so a
-- conclusion drawn before a data update cannot live on beside the new tables.
function Instance:put(guid, record, now)
  record.lastSeen = now
  self.store.players[guid] = record
  self.store.schemaVersion = self.config.schemaVersion
end

function Instance:get(guid)
  return self.store.players[guid]
end

function Instance:isStale(guid, now)
  local record = self.store.players[guid]
  if not record or not record.lastSeen then return true end
  return (now - record.lastSeen) > self.config.staleSeconds
end

function Instance:prune(now)
  local dropped = 0
  for guid, record in pairs(self.store.players) do
    if not record.lastSeen or (now - record.lastSeen) > self.config.pruneSeconds then
      self.store.players[guid] = nil
      dropped = dropped + 1
    end
  end
  return dropped
end

-- On a version mismatch the store is discarded rather than migrated. A
-- half-migrated cache renders as confident data that was derived under
-- different rules, which is the failure this whole design exists to avoid.
function Instance:migrate()
  if self.store.schemaVersion ~= self.config.schemaVersion then
    self.store.players = {}
    self.store.schemaVersion = self.config.schemaVersion
  end
end
