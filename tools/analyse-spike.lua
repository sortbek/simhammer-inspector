-- Eenmalig analysescript: laadt de SavedVariables van de spike en draait de
-- echte LinkParser eroverheen. Bedoeld om de aannames uit de spec te toetsen,
-- niet om onderdeel van de addon te worden.

local svPath = ...
assert(svPath, "gebruik: lua5.1.exe tools/analyse-spike.lua <pad naar SavedVariables>")

local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()

local db = env.RaidInspectorSpikeDB
assert(db, "geen RaidInspectorSpikeDB gevonden")

local ns = {}
assert(loadfile("RaidInspector/LinkParser.lua"))("RaidInspector", ns)
local parse = ns.LinkParser.parse

local SLOTNAMES = {
  [1]="helm", [2]="nek", [3]="shoulders", [5]="chest", [6]="riem", [7]="benen",
  [8]="boots", [9]="bracers", [10]="handen", [11]="ring1", [12]="ring2",
  [13]="trinket1", [14]="trinket2", [15]="cloak", [16]="mainhand", [17]="offhand",
}

local totalSlots, parseFailures = 0, 0
local socketDisagree, socketSamples = 0, 0
local enchantedSlots, upgradeLines = {}, 0
local negativeModifiers = 0
local maxBonusCount, maxModCount = 0, 0

print("=== captures ===")
for i = 1, table.getn(db) do
  local e = db[i]
  local n = 0
  for _ in pairs(e.slots) do n = n + 1 end
  print(string.format("%-28s %2d slots", e.label or "?", n))
end

print("")
print("=== parser tegen echte links ===")
for i = 1, table.getn(db) do
  for slot, data in pairs(db[i].slots) do
    totalSlots = totalSlots + 1
    local p = parse(data.link)
    if not p then
      parseFailures = parseFailures + 1
      print("PARSE MISLUKT slot " .. slot .. ": " .. tostring(data.link))
    else
      if p.enchantID ~= 0 then
        enchantedSlots[slot] = (enchantedSlots[slot] or 0) + 1
      end
      local nb = table.getn(p.bonusIDs)
      if nb > maxBonusCount then maxBonusCount = nb end
      local nm = 0
      for k, v in pairs(p.modifiers) do
        nm = nm + 1
        if v < 0 then negativeModifiers = negativeModifiers + 1 end
      end
      if nm > maxModCount then maxModCount = nm end

      -- Socketcount: vergelijk de twee kandidaat-APIs.
      local s = data.sockets
      if type(s.fromGetItemStats) == "number" and type(s.fromGetItemNumSockets) == "number" then
        socketSamples = socketSamples + 1
        if s.fromGetItemStats ~= s.fromGetItemNumSockets then
          socketDisagree = socketDisagree + 1
          print(string.format("SOCKET-VERSCHIL slot %d: stats=%s numSockets=%s added=%s",
                slot, tostring(s.fromGetItemStats), tostring(s.fromGetItemNumSockets),
                tostring(s.fromGetItemNumAddedSockets)))
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

print("")
print(string.format("slots totaal          : %d", totalSlots))
print(string.format("parse mislukt         : %d", parseFailures))
print(string.format("socket-vergelijkingen : %d, verschillen: %d", socketSamples, socketDisagree))
print(string.format("negatieve modifiers   : %d", negativeModifiers))
print(string.format("max bonus-IDs         : %d", maxBonusCount))
print(string.format("max modifier-paren    : %d", maxModCount))
print(string.format("items met upgradeline : %d", upgradeLines))

print("")
print("=== slots met een enchant ===")
for slot = 1, 17 do
  if enchantedSlots[slot] then
    print(string.format("  %-10s (%2d) : %d keer", SLOTNAMES[slot] or "?", slot, enchantedSlots[slot]))
  end
end
