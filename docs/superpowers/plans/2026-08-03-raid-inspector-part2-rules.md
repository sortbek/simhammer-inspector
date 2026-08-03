# Raid Inspector — Implementation plan, part 2: completing the rules

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the rules engine — upgrade tracks, empty sockets and missing sockets — and build the degradation logic that makes outdated data go quiet rather than quietly wrong.

**Architecture:** Everything in this plan is pure and runs offline under Lua 5.1. That is possible because the spike of 2026-08-03 produced real hydrated data: 184 items with their socket counts, tooltip lines, set IDs and item levels. That corpus replaces the WoW API entirely during testing.

**Tech stack:** Lua 5.1.5 from `tools/lua/`, the test runner from part 1.

## Scope of this plan

Part 1 delivered `LinkParser`, `Evidence`, `Policy` and half of `Rules`. This plan completes
`Rules`. What remains after it:

- **Part 3: the data generator.** Deliberately deferred. `wago.tools` serves the CSVs
  (verified: `https://wago.tools/db2/SpellItemEnchantment/csv?build=12.0.7.68887` returns
  543 KB), but whether the Silver/Gold quality tier can be derived from it directly is
  unknown — that runs through a chain of scroll item to spell to enchantment. It deserves the
  same treatment as the in-game spike: measure first, then build.
- **Part 4: the runtime.** `Scanner`, `Hydrator`, `Cache`. Requires the game.
- **Part 5: the UI.** Grid and detail panel.

## Global constraints

Unchanged from part 1, and they hold in full:

- **Target runtime is Lua 5.1.** Forbidden: `goto`, `//`, native bitwise operators, `\z`,
  `table.unpack` (use `unpack`).
- **No WoW globals in pure modules.** The harness does not shim them.
- **No `#` on tables with holes.** Count explicitly.
- **No assumptions about integer width.** Everything stays below 2^53.
- Addon folder and namespace: `RaidInspector`. LF line endings, UTF-8 without BOM.
- All source, comments, test names, documentation and commit messages in English.

## What the spike established, and what this plan builds on it

- `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` = `Upgrade Level: %s %d/%d`.
- Observed variants: `Myth 1/6`, `Myth 2/6`, `Myth 3/6`, `Myth 5/6`, `Myth 6/6`,
  `Hero 3/6`, `Hero 6/6`.
- **106 of 184 items carried an upgrade line, 78 did not.** Absence is therefore *not*
  evidence of "fully upgraded" — that must stay `unknown`.
- **`hasDynamicData` was absent on all 184 items.** The field does not exist in practice, so
  tooltip completeness has to be judged from the lines, not from a flag.
- `C_Item.GetItemStats` and `C_Item.GetItemNumSockets` agreed on all 184 items. The only
  socket line observed is `Prismatic Socket`.

---

### Task 1: Hydrated fixtures from the spike data

**Files:**
- Create: `tools/extract-hydrated.lua`
- Create: `spec/fixtures/hydrated.lua` (generated)
- Create: `spec/fixtures/tooltips.lua`

**Interfaces:**
- Produces: `spec/fixtures/hydrated.lua` returns a dense array of records shaped
  `{ player, slot, link, socketCount, setID, ilvl, tooltip }`, where `tooltip` is a dense
  array of strings. Tasks 2 through 4 test against it.
- Produces: `spec/fixtures/tooltips.lua` returns `{ formatString, withTrack, withoutTrack,
  socketedCrafted }`, where `withTrack` is an array of the seven real upgrade lines.

- [ ] **Step 1: Write the extraction script**

Create `tools/extract-hydrated.lua`:

```lua
-- Turns the spike's SavedVariables into a test fixture. One-off helper, not part
-- of the addon. Run with:
--   tools\lua\lua5.1.exe tools\extract-hydrated.lua <path> > spec\fixtures\hydrated.lua

local svPath = ...
assert(svPath, "usage: lua5.1.exe tools/extract-hydrated.lua <path>")

local env = {}
local chunk = assert(loadfile(svPath))
setfenv(chunk, env)
chunk()
local db = assert(env.RaidInspectorSpikeDB, "no RaidInspectorSpikeDB found")

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
```

- [ ] **Step 2: Generate the fixture**

Do **not** use `Set-Content -Encoding utf8` here: Windows PowerShell 5.1 writes a BOM, and
Lua 5.1 fails to parse the file with `unexpected symbol near '<bom>'`. It also violates the
project's UTF-8-without-BOM constraint. Write the file explicitly instead:

```powershell
$sv = "C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\JEFFWIENEN\SavedVariables\RaidInspectorSpike.lua"
$out = & "tools\lua\lua5.1.exe" "tools\extract-hydrated.lua" $sv
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText("$PWD\spec\fixtures\hydrated.lua", ($out -join "`n") + "`n", $utf8NoBom)
& "tools\lua\lua5.1.exe" -e "local t = dofile('spec/fixtures/hydrated.lua'); print(table.getn(t) .. ' records')"
```

Expected: `184 records`. A different number is fine if more captures were collected since;
what matters is that the file loads and the count is non-zero.

- [ ] **Step 3: Write the tooltip fixture by hand**

This one is small and explicit, because the tests hang literal expectations on it.
Create `spec/fixtures/tooltips.lua`:

```lua
-- Real tooltip lines from the spike. formatString is the value
-- ITEM_UPGRADE_TOOLTIP_FORMAT_STRING returned in game on 12.0.7.

return {
  formatString = "Upgrade Level: %s %d/%d",

  withTrack = {
    "Upgrade Level: Myth 6/6",
    "Upgrade Level: Myth 5/6",
    "Upgrade Level: Myth 3/6",
    "Upgrade Level: Myth 2/6",
    "Upgrade Level: Myth 1/6",
    "Upgrade Level: Hero 6/6",
    "Upgrade Level: Hero 3/6",
  },

  -- A real trinket tooltip with no upgrade line. 78 of 184 items looked like
  -- this, so absence is not evidence of "fully upgraded".
  withoutTrack = {
    "Gaze of the Alnseer",
    "Item Level 298",
    "Binds when picked up",
    "Unique-Equipped",
    "Trinket",
    "+123 Mastery",
    "+55 Avoidance",
  },

  -- A real bracer tooltip with a socket and an embellishment.
  socketedCrafted = {
    "Silvermoon Agent's Deflectors",
    "Radiance Crafted",
    "Item Level 285",
    "Binds when picked up",
    "Unique-Equipped: Embellished (2)",
    "Wrist",
    "72 Armor",
    "+67 Intellect",
    "Prismatic Socket",
  },
}
```

- [ ] **Step 4: Commit**

```powershell
git add tools/extract-hydrated.lua spec/fixtures/hydrated.lua spec/fixtures/tooltips.lua
git commit -m "test: hydrated fixtures from real spike data"
```

---

### Task 2: UpgradeTrackAdapter

**Files:**
- Create: `RaidInspector/UpgradeTrackAdapter.lua`
- Create: `spec/UpgradeTrackAdapter_spec.lua`

**Interfaces:**
- Consumes: `spec/fixtures/tooltips.lua`.
- Produces: `ns.UpgradeTrackAdapter.buildPattern(formatString)` turns Blizzard's global string
  into a Lua pattern with three captures. Works on any locale because the pattern comes from
  the string itself.
- Produces: `ns.UpgradeTrackAdapter.parse(tooltipLines, pattern)` returns
  `{ track = <string>, rank = <number>, max = <number> }`, or `nil` when no line matches.
  `nil` means **unknown**, never "no upgrades remaining".

- [ ] **Step 1: Write the failing tests**

Create `spec/UpgradeTrackAdapter_spec.lua`:

```lua
local helper   = dofile("spec/helper.lua")
local tooltips = dofile("spec/fixtures/tooltips.lua")

local function adapter()
  return helper.loadModules({ "RaidInspector/UpgradeTrackAdapter.lua" }).UpgradeTrackAdapter
end

local function pattern()
  return adapter().buildPattern(tooltips.formatString)
end

describe("UpgradeTrackAdapter pattern building", function()
  it("builds a pattern with three captures from the global string", function()
    local track, rank, max = string.match("Upgrade Level: Myth 6/6", pattern())
    assert.equals("Myth", track)
    assert.equals("6", rank)
    assert.equals("6", max)
  end)

  it("escapes magic characters in the literal segments", function()
    local p = adapter().buildPattern("Rank (%s) %d/%d")
    local track, rank, max = string.match("Rank (Hero) 3/6", p)
    assert.equals("Hero", track)
    assert.equals("3", rank)
    assert.equals("6", max)
  end)

  it("handles a track name containing a space", function()
    local track = string.match("Upgrade Level: Explorer Plus 2/8", pattern())
    assert.equals("Explorer Plus", track)
  end)

  it("works on a non-English format string", function()
    local p = adapter().buildPattern("Verbesserungsstufe: %s %d/%d")
    local track, rank = string.match("Verbesserungsstufe: Mythisch 4/6", p)
    assert.equals("Mythisch", track)
    assert.equals("4", rank)
  end)
end)

describe("UpgradeTrackAdapter parsing", function()
  it("recognises every real upgrade line from the spike", function()
    local A, p = adapter(), pattern()
    for i = 1, table.getn(tooltips.withTrack) do
      local line = tooltips.withTrack[i]
      local r = A.parse({ line }, p)
      assert.truthy(r, "no match on: " .. line)
      assert.truthy(r.rank >= 1 and r.rank <= r.max)
    end
  end)

  it("returns track, rank and max with the right types", function()
    local r = adapter().parse({ "Upgrade Level: Hero 3/6" }, pattern())
    assert.equals("Hero", r.track)
    assert.equals(3, r.rank)
    assert.equals(6, r.max)
  end)

  it("finds the line in the middle of a full tooltip", function()
    local lines = { "Name", "Item Level 298", "Upgrade Level: Myth 5/6", "+123 Mastery" }
    local r = adapter().parse(lines, pattern())
    assert.equals("Myth", r.track)
    assert.equals(5, r.rank)
  end)

  it("returns nil when there is no upgrade line", function()
    assert.is_nil(adapter().parse(tooltips.withoutTrack, pattern()))
  end)

  it("returns nil for an empty or missing tooltip", function()
    local A, p = adapter(), pattern()
    assert.is_nil(A.parse({}, p))
    assert.is_nil(A.parse(nil, p))
  end)

  it("ignores non-string lines without crashing", function()
    local r = adapter().parse({ 42, false, "Upgrade Level: Myth 1/6" }, pattern())
    assert.equals(1, r.rank)
  end)
end)
```

- [ ] **Step 2: Run the tests and verify they fail**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "UpgradeTrackAdapter"
```

Expected: ten failures with "could not load: .../RaidInspector/UpgradeTrackAdapter.lua".

- [ ] **Step 3: Write the implementation**

Create `RaidInspector/UpgradeTrackAdapter.lua`:

```lua
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
```

- [ ] **Step 4: Run the tests and verify they pass**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "UpgradeTrackAdapter"
```

Expected: `10 passed, 0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add RaidInspector/UpgradeTrackAdapter.lua spec/UpgradeTrackAdapter_spec.lua
git commit -m "feat: UpgradeTrackAdapter reads the track from the tooltip"
```

---

### Task 3: Rules — item shape and upgrades_left

**Files:**
- Modify: `RaidInspector/Rules.lua`
- Modify: `spec/Rules_spec.lua`

**Interfaces:**
- Changes: `ns.Rules.evaluateSlot(slot, item, slotRecord, context)`. The second parameter is
  no longer the raw parse result but an **item record**:
  `{ parsed = <parse result>, socketCount = <number or nil>, upgrade = <table or nil>, setID = <number or nil> }`.
  `nil` as the second parameter still means an empty slot.
- Changes: the entries `evaluatePlayer` expects carry the same fields.
- Produces: a new finding, `upgrades_left`.

The signature change is necessary because three of the remaining checks need hydrated data
that does not come from the item link. Passing them as separate parameters would make the
signature grow with every new source.

- [ ] **Step 1: Adapt the existing tests to the new shape**

Add a helper to `spec/Rules_spec.lua`, right after `local CONTEXT = ...`:

```lua
-- Builds the item record evaluateSlot expects. Without this wrapper every test
-- would have to assemble a table that has nothing to do with the test.
local function item(parsedItem, extra)
  local it = { parsed = parsedItem }
  if extra then
    it.socketCount = extra.socketCount
    it.upgrade     = extra.upgrade
    it.setID       = extra.setID
  end
  return it
end
```

Then, in every existing call to `ns.Rules.evaluateSlot`, replace the second argument
`parsed(...)` with `item(parsed(...))`. That is twelve places across "Rules enchants",
"Rules gems" and "Rules empty slot". Calls passing `nil` as the second argument stay `nil`.

Also adapt `slotEntry` in "Rules player-wide checks":

```lua
  local function slotEntry(ns, opts)
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 100)
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 120)
    return {
      parsed      = opts.parsed or parsed(7364, nil, 0, opts.bonusIDs),
      record      = rec,
      setID       = opts.setID,
      socketCount = opts.socketCount,
      upgrade     = opts.upgrade,
    }
  end
```

- [ ] **Step 2: Write the new failing tests**

Add to `spec/Rules_spec.lua`, after the "Rules gems" block:

```lua
describe("Rules upgrade track", function()
  it("reports nothing on a fully upgraded item", function()
    local ns = fresh()
    local it = item(parsed(7364), { upgrade = { track = "Myth", rank = 6, max = 6 } })
    local findings = ns.Rules.evaluateSlot(1, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "upgrades_left"))
  end)

  it("reports remaining upgrades as a warning", function()
    local ns = fresh()
    local it = item(parsed(7364), { upgrade = { track = "Hero", rank = 3, max = 6 } })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, it, confirmedRecord(ns, "a"), CONTEXT), "upgrades_left")
    assert.equals("warn", f.severity)
    assert.equals("bad", f.state)
    assert.matches("3/6", f.detail)
    assert.matches("Hero", f.detail)
  end)

  -- The case the spike surfaced: 78 of 184 items had no upgrade line. Those must
  -- not count as fully upgraded.
  it("reports nothing when the track is unknown", function()
    local ns = fresh()
    local findings = ns.Rules.evaluateSlot(1, item(parsed(7364)),
                                           confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "upgrades_left"))
  end)

  it("uses the denominator from the tooltip rather than a hardcoded six", function()
    local ns = fresh()
    local it = item(parsed(7364), { upgrade = { track = "Explorer", rank = 2, max = 8 } })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, it, confirmedRecord(ns, "a"), CONTEXT), "upgrades_left")
    assert.matches("2/8", f.detail)
  end)

  it("requires confirmed tooltip evidence before turning bad", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, "a", { linkComplete = true, tooltipComplete = false }, 100)
    ns.Evidence.record(rec, "a", { linkComplete = true, tooltipComplete = false }, 120)
    local it = item(parsed(7364), { upgrade = { track = "Hero", rank = 3, max = 6 } })
    local f = findingOfKind(ns.Rules.evaluateSlot(1, it, rec, CONTEXT), "upgrades_left")
    assert.equals("unknown", f.state)
  end)
end)
```

- [ ] **Step 3: Run the tests and verify they fail**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Rules"
```

Expected: the five new tests fail. **Six** of the twelve adapted tests fail as well, because
`evaluateSlot` now receives an item record where it expects a parse result. The other six
adapted tests pass vacuously: they only assert `is_nil`, and an item record read as a parse
result produces a `missing_item` finding rather than the enchant finding they look for. That
is exactly the kind of silently-passing test the refactor has to fix, so do not take those
six as evidence that anything works.

- [ ] **Step 4: Adapt the implementation**

Add to `RaidInspector/Rules.lua`, before `Rules.evaluateSlot`:

```lua
local function checkUpgrade(findings, slot, upgrade, slotRecord, context)
  -- No upgrade information means UNKNOWN. The spike showed 78 of 184 items have
  -- no upgrade line in the tooltip; they are not all fully upgraded, so staying
  -- silent here is the only correct choice.
  if not upgrade then return end
  if not upgrade.rank or not upgrade.max then return end

  if upgrade.rank < upgrade.max then
    add(findings, slot, "upgrades_left", "warn",
        stateFor(slotRecord, { "tooltipComplete" }, context),
        upgrade.rank .. "/" .. upgrade.max .. " " .. tostring(upgrade.track))
  end
end
```

Replace `Rules.evaluateSlot` with:

```lua
function Rules.evaluateSlot(slot, item, slotRecord, context)
  local findings = {}

  if not item or not item.parsed then
    -- A two-handed weapon makes an empty off-hand correct, not a finding.
    local isEmptyOffhandWithTwoHander = (slot == 17 and context.twoHanded)
    if not isEmptyOffhandWithTwoHander then
      add(findings, slot, "missing_item", "error",
          stateFor(slotRecord, { "itemLoaded" }, context),
          "no item in this slot")
    end
    return findings
  end

  checkEnchant(findings, slot, item.parsed, slotRecord, context)
  checkGems(findings, slot, item.parsed, slotRecord, context)
  checkUpgrade(findings, slot, item.upgrade, slotRecord, context)

  return findings
end
```

In `Rules.evaluatePlayer`, pass the whole entry:

```lua
  for slot, entry in pairs(slots) do
    local slotFindings = Rules.evaluateSlot(slot, entry, entry.record, context)
    for i = 1, table.getn(slotFindings) do
      findings[table.getn(findings) + 1] = slotFindings[i]
    end
  end
```

`countEmbellishments` keeps working unchanged because entries still carry a `parsed` field;
verify that explicitly rather than assuming it.

- [ ] **Step 5: Run the tests and verify they pass**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Rules"
```

Expected: `24 passed, 0 failed` — the nineteen from part 1 plus the five new ones.

- [ ] **Step 6: Commit**

```powershell
git add RaidInspector/Rules.lua spec/Rules_spec.lua
git commit -m "feat: Rules reports remaining upgrades and works on an item record"
```

---

### Task 4: Rules — empty and missing sockets

**Files:**
- Modify: `RaidInspector/Rules.lua`
- Modify: `spec/Rules_spec.lua`

**Interfaces:**
- Produces: two new findings, `empty_socket` (error) and `missing_socket` (warning).

Mind the trap the spec calls out: the `EMPTY_SOCKET_*` keys from `C_Item.GetItemStats` mean
"there is a socket here", **not** "this socket is empty". The spike confirmed it — a bracer
with a filled Prismatic Socket returned `1`. The number of empty sockets is therefore
`socketCount` minus the number of gems in the link.

- [ ] **Step 1: Write the failing tests**

Add to `spec/Rules_spec.lua`, after the "Rules upgrade track" block:

```lua
describe("Rules sockets", function()
  it("reports nothing when every socket is filled", function()
    local ns = fresh()
    local it = item(parsed(7364, { 213743, 0, 0, 0 }, 1), { socketCount = 1 })
    local findings = ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "empty_socket"))
  end)

  it("reports an empty socket as an error", function()
    local ns = fresh()
    local it = item(parsed(7364), { socketCount = 1 })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT), "empty_socket")
    assert.equals("error", f.severity)
    assert.equals("bad", f.state)
    assert.matches("1", f.detail)
  end)

  it("counts multiple empty sockets", function()
    local ns = fresh()
    local it = item(parsed(7364, { 213743, 0, 0, 0 }, 1), { socketCount = 3 })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT), "empty_socket")
    assert.matches("2", f.detail)
  end)

  it("stays silent while the socket count is unknown", function()
    local ns = fresh()
    local it = item(parsed(7364), { socketCount = nil })
    local findings = ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "empty_socket"))
  end)

  it("requires confirmed socket evidence before turning bad", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, "a", { linkComplete = true, socketsKnown = false }, 100)
    ns.Evidence.record(rec, "a", { linkComplete = true, socketsKnown = false }, 120)
    local it = item(parsed(7364), { socketCount = 1 })
    local f = findingOfKind(ns.Rules.evaluateSlot(5, it, rec, CONTEXT), "empty_socket")
    assert.equals("unknown", f.state)
  end)

  it("reports a socketable slot without a socket as a warning", function()
    local ns = fresh()
    local it = item(parsed(7364), { socketCount = 0 })
    local f = findingOfKind(
      ns.Rules.evaluateSlot(9, it, confirmedRecord(ns, "a"), CONTEXT), "missing_socket")
    assert.equals("warn", f.severity)
  end)

  it("reports no missing socket on a slot that cannot take one", function()
    local ns = fresh()
    local it = item(parsed(7364), { socketCount = 0 })
    local findings = ns.Rules.evaluateSlot(5, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_socket"))
  end)

  it("reports no missing socket when a socket is already present", function()
    local ns = fresh()
    local it = item(parsed(7364, { 213743, 0, 0, 0 }, 1), { socketCount = 1 })
    local findings = ns.Rules.evaluateSlot(9, it, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_socket"))
  end)
end)
```

- [ ] **Step 2: Run the tests and verify they fail**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Rules sockets"
```

Expected: eight failures.

- [ ] **Step 3: Write the implementation**

Add to `RaidInspector/Rules.lua`, right after `checkUpgrade`:

```lua
local function checkSockets(findings, slot, item, slotRecord, context)
  local socketCount = item.socketCount

  -- An unknown socket count means staying silent. You can conclude neither
  -- "empty" nor "missing" from it.
  if type(socketCount) ~= "number" then return end

  if socketCount > 0 then
    -- The EMPTY_SOCKET_* keys mean "there is a socket here", not "this socket is
    -- empty". Empty count is therefore total minus the gems in the link.
    local empty = socketCount - (item.parsed.gemCount or 0)
    if empty > 0 then
      add(findings, slot, "empty_socket", "error",
          stateFor(slotRecord, { "linkComplete", "socketsKnown" }, context),
          empty .. " of " .. socketCount .. " sockets empty")
    end
    return
  end

  if ns.Policy.Slots.isSocketable(slot) then
    add(findings, slot, "missing_socket", "warn",
        stateFor(slotRecord, { "socketsKnown" }, context),
        "this slot can take a socket but has none")
  end
end
```

Call it in `Rules.evaluateSlot`, after `checkUpgrade`:

```lua
  checkSockets(findings, slot, item, slotRecord, context)
```

- [ ] **Step 4: Run every test and verify they pass**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

Expected: `81 passed, 0 failed` — the 58 from part 1, plus ten adapter tests, plus five
upgrade tests, plus eight socket tests. If the number differs, work out which test is missing
rather than adjusting the expected number.

- [ ] **Step 5: Commit**

```powershell
git add RaidInspector/Rules.lua spec/Rules_spec.lua
git commit -m "feat: Rules reports empty and missing sockets"
```

---

### Task 5: DataVersion — degrade on patch version

**Files:**
- Create: `RaidInspector/DataVersion.lua`
- Create: `RaidInspector/Data/Version.lua`
- Create: `spec/DataVersion_spec.lua`

**Interfaces:**
- Produces: `ns.DataVersion.compare(dataVersion, gameVersion)` returns `"current"`,
  `"newer-build"` or `"newer-patch"`. Versions are tables `{ version = "12.0.7", build = "68887" }`.
- Produces: `ns.DataVersion.isValid(status)` returns `false` only for `"newer-patch"` — that
  is the value feeding `context.dataValid`.

This is the fix the review flagged as most important. Degrading on **build number** would put
the addon out of action for most of every season, because build numbers rise almost weekly
through hotfixes that touch no items. Only a newer **patch version** may hard-degrade; a
newer build within the same patch produces a soft notice.

- [ ] **Step 1: Write the failing tests**

Create `spec/DataVersion_spec.lua`:

```lua
local helper = dofile("spec/helper.lua")

local function dv()
  return helper.loadModules({ "RaidInspector/DataVersion.lua" }).DataVersion
end

describe("DataVersion comparison", function()
  it("calls equal versions current", function()
    assert.equals("current", dv().compare({ version = "12.0.7", build = "68887" },
                                          { version = "12.0.7", build = "68887" }))
  end)

  it("treats a newer build within the same patch as no problem", function()
    assert.equals("newer-build", dv().compare({ version = "12.0.7", build = "68887" },
                                              { version = "12.0.7", build = "69120" }))
  end)

  it("treats a newer patch version as a problem", function()
    assert.equals("newer-patch", dv().compare({ version = "12.0.7", build = "68887" },
                                              { version = "12.1.0", build = "69000" }))
  end)

  it("recognises a newer major version too", function()
    assert.equals("newer-patch", dv().compare({ version = "12.0.7", build = "68887" },
                                              { version = "13.0.0", build = "70000" }))
  end)

  it("calls an older game version current", function()
    assert.equals("current", dv().compare({ version = "12.0.7", build = "68887" },
                                          { version = "12.0.5", build = "68000" }))
  end)

  it("returns newer-patch for unparseable versions, because silence is safer", function()
    assert.equals("newer-patch", dv().compare({ version = nil }, { version = "12.0.7" }))
  end)
end)

describe("DataVersion validity", function()
  it("allows current data", function()
    assert.truthy(dv().isValid("current"))
  end)

  it("allows a newer build", function()
    assert.truthy(dv().isValid("newer-build"))
  end)

  it("blocks on a newer patch", function()
    assert.falsy(dv().isValid("newer-patch"))
  end)
end)
```

- [ ] **Step 2: Run the tests and verify they fail**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "DataVersion"
```

Expected: nine failures with "could not load".

- [ ] **Step 3: Write the implementation**

Create `RaidInspector/DataVersion.lua`:

```lua
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
```

- [ ] **Step 4: Write the generated version file**

Create `RaidInspector/Data/Version.lua`:

```lua
local addonName, ns = ...

ns.Data = ns.Data or {}

-- GENERATED in part 3. Until then filled in by hand with the version the stub
-- tables are based on.
ns.Data.Version = {
  version = "12.0.7",
  build   = "68887",
}
```

- [ ] **Step 5: Run every test and verify they pass**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

Expected: `90 passed, 0 failed`.

- [ ] **Step 6: Commit**

```powershell
git add RaidInspector/DataVersion.lua RaidInspector/Data/Version.lua spec/DataVersion_spec.lua
git commit -m "feat: DataVersion degrades on patch version rather than build number"
```

---

## What remains after this plan

- **Part 3: the data generator.** `tools/generate.mjs` fetches the wago.tools CSVs and writes
  `Data/*.lua`. Preceded by a schema exploration, because the chain from enchant ID to
  quality tier has not been mapped yet.
- **Part 4: the runtime.** `Scanner` with its three queues, `Hydrator` with a failure path,
  `Cache` with schema version and TTL. Requires the game, and has to measure how many passes
  are actually needed before a player is confirmed — the spike showed a single inspect can
  return 2 to 15 slots.
- **Part 5: the UI.** Grid with summary column, detail panel, coverage bar.
