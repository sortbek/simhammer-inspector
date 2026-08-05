local addonName, ns = ...

local Evidence = {}
ns.Evidence = Evidence

-- "absent" is the evidence that a slot is empty. It has to be a source like any
-- other: an inspect that answered and returned no link for a slot is a read, not
-- a gap in the data, and without recording it there is nothing for the two-reads
-- rule to confirm against. A missing trinket would then be permanently invisible
-- -- the most expensive thing this addon exists to catch.
Evidence.SOURCES = { "linkComplete", "socketsKnown", "tooltipComplete", "itemLoaded", "absent" }

-- djb2, explicitly bounded to 2^32. The bound is not an optimisation but a
-- correctness requirement: WoW runs Lua 5.1 where numbers are doubles with a
-- 53-bit mantissa, while 5.3+ uses 64-bit integers that wrap. Staying under
-- 2^32 makes both versions compute exactly the same value, so a fingerprint
-- computed locally still counts in game.
function Evidence.fingerprint(link)
  if type(link) ~= "string" then return nil end
  local h = 5381
  for i = 1, string.len(link) do
    h = (h * 33 + string.byte(link, i)) % 4294967296
  end
  return h
end

-- The two reads that confirm a negative finding must be this far apart. Owned
-- here because it is a property of the confirmation rule, not of any consumer:
-- the scanner uses it to decide a player is covered, Rules to decide a finding
-- may turn red. Held as two literals those could drift, and the symptom would be
-- a coverage counter reporting a player as done over a grid still showing grey.
Evidence.MIN_INTERVAL = 10

local LINK_ONLY = { "linkComplete" }
local ABSENT_ONLY = { "absent" }

-- Whether a slot's reading is settled, which depends on what is in it: a slot
-- holding an item settles on its link, an empty one on absence reads. Asking for
-- linkComplete on an empty slot waits for evidence that can never arrive, which
-- is how a two-hander's off-hand stayed permanently outstanding and kept its
-- owner parked at the top of a queue with nothing left to learn from them.
function Evidence.isSlotSettled(slotRecord, minInterval)
  if not slotRecord then return false end
  local sources = slotRecord.itemLink and LINK_ONLY or ABSENT_ONLY
  return Evidence.isConfirmed(slotRecord, sources, minInterval)
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
  -- No record is no evidence, which is exactly what this function reports. The
  -- alternative is an error at a call site that is asking a reasonable question
  -- about a player nobody has scanned yet.
  if not slotRecord or not slotRecord.reads then return false end

  for i = 1, table.getn(sources) do
    local r = slotRecord.reads[sources[i]]
    if not r or r.count < 2 then return false end
    if not r.firstAt or not r.lastAt then return false end
    if (r.lastAt - r.firstAt) < minInterval then return false end
  end
  return true
end
