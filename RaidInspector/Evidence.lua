local addonName, ns = ...

local Evidence = {}
ns.Evidence = Evidence

Evidence.SOURCES = { "linkComplete", "socketsKnown", "tooltipComplete", "itemLoaded" }

-- djb2, expliciet begrensd op 2^32. De begrenzing is geen optimalisatie maar
-- een correctheidseis: WoW draait Lua 5.1 waar getallen doubles zijn met een
-- 53-bits mantisse, terwijl 5.3+ 64-bits integers gebruikt die overlopen. Door
-- onder 2^32 te blijven rekenen beide versies exact hetzelfde uit, en telt een
-- fingerprint die lokaal berekend is nog steeds in-game.
function Evidence.fingerprint(link)
  if type(link) ~= "string" then return nil end
  local h = 5381
  for i = 1, string.len(link) do
    h = (h * 33 + string.byte(link, i)) % 4294967296
  end
  return h
end

function Evidence.newSlotRecord()
  local reads = {}
  for i = 1, table.getn(Evidence.SOURCES) do
    reads[Evidence.SOURCES[i]] = { count = 0, firstAt = nil, lastAt = nil }
  end
  return { fingerprint = nil, reads = reads }
end

function Evidence.record(slotRecord, link, evidence, now)
  local fp = Evidence.fingerprint(link)

  if slotRecord.fingerprint ~= fp then
    slotRecord.fingerprint = fp
    for i = 1, table.getn(Evidence.SOURCES) do
      slotRecord.reads[Evidence.SOURCES[i]] = { count = 0, firstAt = nil, lastAt = nil }
    end
  end

  for i = 1, table.getn(Evidence.SOURCES) do
    local source = Evidence.SOURCES[i]
    if evidence and evidence[source] then
      local r = slotRecord.reads[source]
      r.count = r.count + 1
      r.firstAt = r.firstAt or now
      r.lastAt = now
    end
  end

  return slotRecord
end

function Evidence.isConfirmed(slotRecord, sources, minInterval)
  for i = 1, table.getn(sources) do
    local r = slotRecord.reads[sources[i]]
    if not r or r.count < 2 then return false end
    if not r.firstAt or not r.lastAt then return false end
    if (r.lastAt - r.firstAt) < minInterval then return false end
  end
  return true
end
