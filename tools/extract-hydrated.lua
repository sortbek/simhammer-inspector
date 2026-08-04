-- Turns the spike's SavedVariables into a test fixture. One-off helper, not part
-- of the addon. Run with:
--   tools\lua\lua5.1.exe tools\extract-hydrated.lua <path> > spec\fixtures\hydrated.lua

local svPath = ...
assert(svPath, "usage: lua5.1.exe tools/extract-hydrated.lua <path>")

local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()
local db = assert(env.SimhammerInspectorSpikeDB, "no SimhammerInspectorSpikeDB found")

print("-- GENERATED from spike data, Midnight 12.0.7 build 68887.")
print("-- Do not edit by hand; regenerate with tools/extract-hydrated.lua.")
print("")
print("return {")

for i = 1, table.getn(db) do
  local entry = db[i]
  local slots = {}
  for slot in pairs(entry.slots) do slots[table.getn(slots) + 1] = slot end
  table.sort(slots)

  for j = 1, table.getn(slots) do
    local slot = slots[j]
    local data = entry.slots[slot]
    print("  {")
    print(string.format("    player = %q, slot = %d,", entry.name or "?", slot))
    print(string.format("    link = %q,", data.link))
    print(string.format("    socketCount = %s,",
          type(data.sockets.fromGetItemStats) == "number"
          and tostring(data.sockets.fromGetItemStats) or "nil"))
    print(string.format("    setID = %s, ilvl = %s,",
          tostring(data.setID or "nil"), tostring(data.ilvl or "nil")))
    print("    tooltip = {")
    for k = 1, table.getn(data.tooltip) do
      if type(data.tooltip[k]) == "string" then
        print(string.format("      %q,", data.tooltip[k]))
      end
    end
    print("    },")
    print("  },")
  end
end

print("}")
