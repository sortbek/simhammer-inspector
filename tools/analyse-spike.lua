-- Analyses the spike's SavedVariables: runs the real LinkParser over every
-- captured link and summarises what the data says about the assumptions in the
-- spec. Re-run this after collecting new captures.
--
--   tools\lua\lua5.1.exe tools\analyse-spike.lua <path to SavedVariables>

local svPath = ...
assert(svPath, "usage: lua5.1.exe tools/analyse-spike.lua <path>")

local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()
local db = assert(env.SimhammerInspectorSpikeDB, "no SimhammerInspectorSpikeDB found")

local ns = {}
assert(loadfile("LinkParser.lua"))("SimhammerInspector", ns)
local parse = ns.LinkParser.parse

local SLOTNAMES = {
  [1] = "head", [2] = "neck", [3] = "shoulders", [5] = "chest", [6] = "waist",
  [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands", [11] = "finger1",
  [12] = "finger2", [13] = "trinket1", [14] = "trinket2", [15] = "back",
  [16] = "mainhand", [17] = "offhand",
}

local totalSlots, parseFailures = 0, 0
local socketSamples, socketDisagree = 0, 0
local negativeModifiers, upgradeLines = 0, 0
local maxBonusCount, maxModCount = 0, 0
local seen, enchanted = {}, {}

print("=== captures ===")
for i = 1, table.getn(db) do
  local e = db[i]
  local n = 0
  for _ in pairs(e.slots) do n = n + 1 end
  print(string.format("%-28s %2d slots", e.label or "?", n))
end

print("")
for i = 1, table.getn(db) do
  for slot, data in pairs(db[i].slots) do
    totalSlots = totalSlots + 1
    seen[slot] = (seen[slot] or 0) + 1

    local p = parse(data.link)
    if not p then
      parseFailures = parseFailures + 1
      print("PARSE FAILED slot " .. slot .. ": " .. tostring(data.link))
    else
      if p.enchantID ~= 0 then enchanted[slot] = (enchanted[slot] or 0) + 1 end

      local nb = table.getn(p.bonusIDs)
      if nb > maxBonusCount then maxBonusCount = nb end

      local nm = 0
      for _, v in pairs(p.modifiers) do
        nm = nm + 1
        if v < 0 then negativeModifiers = negativeModifiers + 1 end
      end
      if nm > maxModCount then maxModCount = nm end

      local s = data.sockets
      if type(s.fromGetItemStats) == "number"
         and type(s.fromGetItemNumSockets) == "number" then
        socketSamples = socketSamples + 1
        if s.fromGetItemStats ~= s.fromGetItemNumSockets then
          socketDisagree = socketDisagree + 1
          print(string.format("SOCKET MISMATCH slot %d: stats=%s numSockets=%s",
                slot, tostring(s.fromGetItemStats), tostring(s.fromGetItemNumSockets)))
        end
      end

      for _, line in ipairs(data.tooltip) do
        if type(line) == "string" and string.find(line, "Upgrade Level", 1, true) then
          upgradeLines = upgradeLines + 1
        end
      end
    end
  end
end

print(string.format("slots total            : %d", totalSlots))
print(string.format("parse failures         : %d", parseFailures))
print(string.format("socket comparisons     : %d, mismatches: %d", socketSamples, socketDisagree))
print(string.format("negative modifiers     : %d", negativeModifiers))
print(string.format("max bonus IDs          : %d", maxBonusCount))
print(string.format("max modifier pairs     : %d", maxModCount))
print(string.format("items with upgrade line: %d", upgradeLines))

print("")
print("slot            seen  enchanted")
for slot = 1, 17 do
  if SLOTNAMES[slot] then
    print(string.format("  %-10s (%2d) %5d %10d", SLOTNAMES[slot], slot,
          seen[slot] or 0, enchanted[slot] or 0))
  end
end
