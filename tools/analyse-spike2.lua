local svPath = ...
local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()
local db = env.RaidInspectorSpikeDB

local ns = {}
assert(loadfile("RaidInspector/LinkParser.lua"))("RaidInspector", ns)
local parse = ns.LinkParser.parse

local SLOTNAMES = {
  [1]="helm", [2]="nek", [3]="shoulders", [5]="chest", [6]="riem", [7]="benen",
  [8]="boots", [9]="bracers", [10]="handen", [11]="ring1", [12]="ring2",
  [13]="trinket1", [14]="trinket2", [15]="cloak", [16]="mainhand", [17]="offhand",
}

local seen, enchanted = {}, {}
local offhands, embellished, socketed = {}, 0, 0

for i = 1, table.getn(db) do
  for slot, data in pairs(db[i].slots) do
    seen[slot] = (seen[slot] or 0) + 1
    local p = parse(data.link)
    if p and p.enchantID ~= 0 then enchanted[slot] = (enchanted[slot] or 0) + 1 end
    if slot == 17 then
      offhands[table.getn(offhands) + 1] = (data.tooltip[1] or "?") .. " | " ..
        (data.tooltip[6] or data.tooltip[5] or "?") .. " | enchant=" .. tostring(p and p.enchantID)
    end
    for _, line in ipairs(data.tooltip) do
      if type(line) == "string" then
        if string.find(line, "Embellished", 1, true) then embellished = embellished + 1 end
        if string.find(line, "Socket", 1, true) then socketed = socketed + 1 end
      end
    end
  end
end

print("slot            gezien  met enchant")
for slot = 1, 17 do
  if SLOTNAMES[slot] then
    print(string.format("  %-10s (%2d) %5d %10d", SLOTNAMES[slot], slot,
          seen[slot] or 0, enchanted[slot] or 0))
  end
end

print("")
print("off-hand items:")
for i = 1, table.getn(offhands) do print("  " .. offhands[i]) end
print("")
print("tooltipregels met 'Embellished': " .. embellished)
print("tooltipregels met 'Socket'     : " .. socketed)
