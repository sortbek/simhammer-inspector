# Raid Inspector — Implementation plan, part 4: the runtime

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the addon actually run in game — scan the raid, hydrate what comes back, persist it, and report findings — without a UI yet.

**Architecture:** The scanner is split in two. `ScanQueue` is pure: which player to inspect next, how the budget is divided, how backoff grows, how the state machine moves. `Scanner` is the thin layer that talks to the WoW API. Without that split the entire scheduling design is unverifiable until you are standing in a raid, which is exactly when you least want to debug it.

**Tech stack:** Lua 5.1.5 from `tools/lua/`, the test runner from part 1.

## Scope

Delivers a working addon that scans and reports to chat. The grid comes in part 5.

| Module | Nature | Verification |
|---|---|---|
| `ScanQueue.lua` | pure | unit tests |
| `Cache.lua` | pure, given an injected clock | unit tests |
| `Hydrator.lua` | async, WoW API | in game |
| `Scanner.lua` | events, WoW API | in game |
| `Roster.lua` | WoW API | in game |
| `Core.lua` | wiring, slash commands | in game |

## Global constraints

Unchanged. Lua 5.1 only; no WoW globals in pure modules; no `#` on tables with holes; all
arithmetic below 2^53; English throughout.

**One addition for this part:** pure modules take time as a parameter, never call `time()` or
`GetTime()`. That is what makes the queue and the cache testable, and it is also what stops
the reconfirmation cadence from being untestable in principle.

## Constants from the spec

| Value | Default |
|---|---|
| Request budget | 5 per 10 s |
| Queue shares | A ≥ 70%, B ~20%, C ≤ 10% |
| Timeout per request | 3 s |
| Backoff | base 5 s, ×2 per consecutive timeout, ceiling 60 s |
| Retry cap per player per pass | 3 |
| `unreachable` after | 5 consecutive timeouts |
| Reprobe of `unreachable` | every 60 s, plus on `UNIT_IN_RANGE_UPDATE` |
| Reconfirmation cadence | every 10 min, **per slot** |
| Minimum interval between confirming reads | 10 s |
| `stale` after | 2 h |
| Cache prune | 30 days |

---

### Task 1: ScanQueue — state machine

**Files:**
- Create: `RaidInspector/ScanQueue.lua`
- Create: `spec/ScanQueue_spec.lua`

**Interfaces:**
- `ns.ScanQueue.new(config)` returns a queue instance. `config` carries the constants above so
  tests can shrink them.
- `queue:addPlayer(guid, now)` registers a player as `unseen`.
- `queue:removePlayer(guid)` drops one.
- `queue:onTimeout(guid, now)` records a failed request.
- `queue:onSuccess(guid, slotsReturned, now)` records a successful pass.
- `queue:onConfirmed(guid, now)` marks every slot confirmed.
- `queue:onInRange(guid, now)` returns an `unreachable` player to the queue.
- `queue:stateOf(guid)` returns one of `unseen`, `queued`, `inflight`, `partial`,
  `confirmed`, `unreachable`, `stale`.

`onSuccess` takes `slotsReturned` because the spike showed an inspect can return anywhere from
2 to 15 of 16 slots. A pass that returned 2 slots is barely evidence and must not move a
player to `confirmed`; the number belongs in the state machine, not only in the log.

- [ ] **Step 1: Write the failing tests**

Create `spec/ScanQueue_spec.lua`:

```lua
local helper = dofile("spec/helper.lua")

local function queue(overrides)
  local ns = helper.loadModules({ "RaidInspector/ScanQueue.lua" })
  local config = {
    timeoutSeconds       = 3,
    backoffBase          = 5,
    backoffCeiling       = 60,
    retryCap             = 3,
    unreachableAfter     = 5,
    reprobeSeconds       = 60,
    reconfirmSeconds     = 600,
    substantialPassSlots = 10,
  }
  for k, v in pairs(overrides or {}) do config[k] = v end
  return ns.ScanQueue.new(config)
end

describe("ScanQueue state machine", function()
  it("starts a new player as unseen", function()
    local q = queue()
    q:addPlayer("A", 100)
    assert.equals("unseen", q:stateOf("A"))
  end)

  it("moves a player to partial after a substantial pass", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:onSuccess("A", 15, 110)
    assert.equals("partial", q:stateOf("A"))
  end)

  -- The spike showed inspects returning as few as 2 of 16 slots. A pass that
  -- thin is not evidence of anything and must not advance the player.
  it("does not advance on a thin pass", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:onSuccess("A", 2, 110)
    assert.equals("unseen", q:stateOf("A"))
  end)

  it("reaches confirmed only when told every slot is confirmed", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:onSuccess("A", 15, 110)
    q:onConfirmed("A", 130)
    assert.equals("confirmed", q:stateOf("A"))
  end)

  it("becomes unreachable after the configured consecutive timeouts", function()
    local q = queue({ unreachableAfter = 3 })
    q:addPlayer("A", 100)
    q:onTimeout("A", 101)
    q:onTimeout("A", 110)
    assert.truthy(q:stateOf("A") ~= "unreachable")
    q:onTimeout("A", 130)
    assert.equals("unreachable", q:stateOf("A"))
  end)

  it("resets the timeout streak on a successful pass", function()
    local q = queue({ unreachableAfter = 3 })
    q:addPlayer("A", 100)
    q:onTimeout("A", 101)
    q:onTimeout("A", 110)
    q:onSuccess("A", 15, 120)
    q:onTimeout("A", 130)
    assert.truthy(q:stateOf("A") ~= "unreachable")
  end)

  -- Without this exit an out-of-range player stays grey all night, which the
  -- design review flagged as a hole in the original state machine.
  it("returns an unreachable player to the queue when they come into range", function()
    local q = queue({ unreachableAfter = 1 })
    q:addPlayer("A", 100)
    q:onTimeout("A", 101)
    assert.equals("unreachable", q:stateOf("A"))
    q:onInRange("A", 200)
    assert.equals("queued", q:stateOf("A"))
  end)

  it("goes stale once the data ages past the reconfirmation window", function()
    local q = queue({ reconfirmSeconds = 100 })
    q:addPlayer("A", 100)
    q:onSuccess("A", 15, 110)
    q:onConfirmed("A", 120)
    assert.equals("confirmed", q:stateOf("A", 150))
    assert.equals("stale", q:stateOf("A", 500))
  end)

  it("forgets a player who left the group", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:removePlayer("A")
    assert.is_nil(q:stateOf("A"))
  end)
end)
```

- [ ] **Step 2: Run the tests and verify they fail**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "ScanQueue state"
```

Expected: nine failures with "could not load: .../RaidInspector/ScanQueue.lua".

- [ ] **Step 3: Write the implementation**

Create `RaidInspector/ScanQueue.lua`:

```lua
local addonName, ns = ...

local ScanQueue = {}
ns.ScanQueue = ScanQueue

local Queue = {}
Queue.__index = Queue

-- Time is always a parameter, never read from the clock. That is what makes the
-- scheduling logic testable at all, and it keeps the reconfirmation cadence from
-- being untestable in principle.
function ScanQueue.new(config)
  return setmetatable({ config = config, players = {} }, Queue)
end

function Queue:addPlayer(guid, now)
  if self.players[guid] then return end
  self.players[guid] = {
    guid = guid,
    state = "unseen",
    timeoutStreak = 0,
    retriesThisPass = 0,
    backoff = 0,
    nextEligibleAt = now,
    lastSuccessAt = nil,
    confirmedAt = nil,
  }
end

function Queue:removePlayer(guid)
  self.players[guid] = nil
end

function Queue:onTimeout(guid, now)
  local p = self.players[guid]
  if not p then return end

  p.timeoutStreak = p.timeoutStreak + 1
  p.retriesThisPass = p.retriesThisPass + 1

  -- Exponential backoff from a stated base. Without a base an implementer has to
  -- invent one, and the schedule silently differs from the spec.
  if p.backoff == 0 then
    p.backoff = self.config.backoffBase
  else
    p.backoff = math.min(p.backoff * 2, self.config.backoffCeiling)
  end
  p.nextEligibleAt = now + p.backoff

  if p.timeoutStreak >= self.config.unreachableAfter then
    p.state = "unreachable"
  end
end

function Queue:onSuccess(guid, slotsReturned, now)
  local p = self.players[guid]
  if not p then return end

  p.timeoutStreak = 0
  p.retriesThisPass = 0
  p.backoff = 0
  p.nextEligibleAt = now

  -- A thin pass still proves the player is reachable, so the streak resets, but
  -- it is not enough to advance the state.
  if slotsReturned >= self.config.substantialPassSlots then
    p.lastSuccessAt = now
    if p.state ~= "confirmed" then p.state = "partial" end
  end
end

function Queue:onConfirmed(guid, now)
  local p = self.players[guid]
  if not p then return end
  p.state = "confirmed"
  p.confirmedAt = now
end

function Queue:onInRange(guid, now)
  local p = self.players[guid]
  if not p then return end
  if p.state == "unreachable" then
    p.state = "queued"
    p.timeoutStreak = 0
    p.backoff = 0
    p.nextEligibleAt = now
  end
end

function Queue:stateOf(guid, now)
  local p = self.players[guid]
  if not p then return nil end

  if p.state == "confirmed" and now and p.confirmedAt then
    if (now - p.confirmedAt) > self.config.reconfirmSeconds then
      return "stale"
    end
  end

  return p.state
end
```

- [ ] **Step 4: Run the tests and verify they pass**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "ScanQueue state"
```

Expected: `9 passed, 0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add RaidInspector/ScanQueue.lua spec/ScanQueue_spec.lua
git commit -m "feat: ScanQueue state machine with a pass-completeness gate"
```

---

### Task 2: ScanQueue — tiers, budget and selection

**Files:**
- Modify: `RaidInspector/ScanQueue.lua`
- Modify: `spec/ScanQueue_spec.lua`

**Interfaces:**
- `queue:setRangeHint(guid, inRange)` records the coarse `UnitInRange` prefilter.
- `queue:tierOf(guid, now)` returns `"A"`, `"B"`, `"C"` or `nil`.
- `queue:next(now)` returns the GUID to inspect next, or `nil` when nothing is eligible.
- `queue:coverage(now)` returns `confirmed, total, unreachableNames`.

`UnitInRange` passes players up to 40 yd while inspect stops at about 28. Without tier shares
a handful of players in that 28–40 yd band absorb the whole budget on timeouts and starve the
raid members standing next to you.

- [ ] **Step 1: Write the failing tests**

Add to `spec/ScanQueue_spec.lua`:

```lua
describe("ScanQueue tiers and selection", function()
  it("puts a fresh in-range player in tier A", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    assert.equals("A", q:tierOf("A", 100))
  end)

  it("puts a confirmed player due for reconfirmation in tier B", function()
    local q = queue({ reconfirmSeconds = 100 })
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    q:onSuccess("A", 15, 110)
    q:onConfirmed("A", 120)
    assert.equals("B", q:tierOf("A", 500))
  end)

  it("puts a player in backoff in tier C", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    q:onTimeout("A", 101)
    assert.equals("C", q:tierOf("A", 102))
  end)

  it("puts an unreachable player in tier C", function()
    local q = queue({ unreachableAfter = 1 })
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    q:onTimeout("A", 101)
    assert.equals("C", q:tierOf("A", 500))
  end)

  it("skips a player the range hint says is out of range", function()
    local q = queue()
    q:addPlayer("A", 100)
    q:setRangeHint("A", false)
    assert.is_nil(q:next(100))
  end)

  it("prefers tier A over tier C", function()
    local q = queue()
    q:addPlayer("cold", 100)
    q:setRangeHint("cold", true)
    q:onTimeout("cold", 101)
    q:addPlayer("warm", 100)
    q:setRangeHint("warm", true)
    assert.equals("warm", q:next(200))
  end)

  -- The starvation guard: a cold player must not be picked while a warm one is
  -- waiting, no matter how long the cold one has been eligible.
  it("does not let tier C starve tier A", function()
    local q = queue()
    for i = 1, 5 do
      local id = "cold" .. i
      q:addPlayer(id, 100)
      q:setRangeHint(id, true)
      q:onTimeout(id, 101)
    end
    q:addPlayer("warm", 100)
    q:setRangeHint("warm", true)
    for _ = 1, 10 do
      assert.equals("warm", q:next(1000))
    end
  end)

  it("returns nil when nothing is eligible", function()
    local q = queue()
    assert.is_nil(q:next(100))
  end)

  it("respects the backoff deadline", function()
    local q = queue({ backoffBase = 50 })
    q:addPlayer("A", 100)
    q:setRangeHint("A", true)
    q:onTimeout("A", 100)
    assert.is_nil(q:next(120))
    assert.equals("A", q:next(200))
  end)

  it("reports coverage as confirmed out of total", function()
    local q = queue()
    q:addPlayer("A", 100); q:setRangeHint("A", true)
    q:addPlayer("B", 100); q:setRangeHint("B", true)
    q:onSuccess("A", 15, 110)
    q:onConfirmed("A", 120)
    local confirmed, total = q:coverage(130)
    assert.equals(1, confirmed)
    assert.equals(2, total)
  end)

  it("lists unreachable players in the coverage report", function()
    local q = queue({ unreachableAfter = 1 })
    q:addPlayer("A", 100); q:setRangeHint("A", true)
    q:onTimeout("A", 101)
    local _, _, unreachable = q:coverage(200)
    assert.equals(1, table.getn(unreachable))
    assert.equals("A", unreachable[1])
  end)
end)
```

- [ ] **Step 2: Run the tests and verify they fail**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "ScanQueue tiers"
```

Expected: eleven failures.

- [ ] **Step 3: Write the implementation**

Add to `RaidInspector/ScanQueue.lua`, before `Queue:stateOf`:

```lua
function Queue:setRangeHint(guid, inRange)
  local p = self.players[guid]
  if p then p.inRange = inRange and true or false end
end

function Queue:tierOf(guid, now)
  local p = self.players[guid]
  if not p then return nil end

  if p.state == "unreachable" then return "C" end
  if p.nextEligibleAt and now < p.nextEligibleAt then return "C" end
  if p.backoff > 0 then return "C" end

  if p.state == "confirmed" then
    if p.confirmedAt and (now - p.confirmedAt) > self.config.reconfirmSeconds then
      return "B"
    end
    return nil
  end

  return "A"
end

-- Selection is strictly A before B before C. The shares in the spec are a
-- budget ceiling for tier C rather than a round-robin: what matters is that a
-- handful of players in the 28-40 yd band cannot absorb the budget while
-- someone standing next to you goes unscanned.
local TIER_ORDER = { "A", "B", "C" }

function Queue:next(now)
  for i = 1, table.getn(TIER_ORDER) do
    local wanted = TIER_ORDER[i]
    local best = nil
    for guid, p in pairs(self.players) do
      if p.inRange and self:tierOf(guid, now) == wanted then
        if not best or p.nextEligibleAt < self.players[best].nextEligibleAt then
          best = guid
        end
      end
    end
    if best then return best end
  end
  return nil
end

function Queue:coverage(now)
  local confirmed, total, unreachable = 0, 0, {}
  for guid, p in pairs(self.players) do
    total = total + 1
    if self:stateOf(guid, now) == "confirmed" then confirmed = confirmed + 1 end
    if p.state == "unreachable" then
      unreachable[table.getn(unreachable) + 1] = guid
    end
  end
  table.sort(unreachable)
  return confirmed, total, unreachable
end
```

- [ ] **Step 4: Run the tests and verify they pass**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "ScanQueue"
```

Expected: `20 passed, 0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add RaidInspector/ScanQueue.lua spec/ScanQueue_spec.lua
git commit -m "feat: ScanQueue tiers and starvation-proof selection"
```

---

### Task 3: Cache

**Files:**
- Create: `RaidInspector/Cache.lua`
- Create: `spec/Cache_spec.lua`

**Interfaces:**
- `ns.Cache.new(store, config)` wraps a SavedVariables table. `store` is a plain table so the
  tests can pass one in.
- `cache:put(guid, record, now)` stores a player record.
- `cache:get(guid)` returns the record or `nil`.
- `cache:isStale(guid, now)` returns `true` past the stale window.
- `cache:prune(now)` drops records older than the prune window; returns how many went.
- `cache:migrate()` discards the store wholesale on a schema version mismatch.

Only raw data is persisted. Derived values are recomputed on load, so a conclusion from before
a data update cannot live on beside the new tables.

- [ ] **Step 1: Write the failing tests**

Create `spec/Cache_spec.lua`:

```lua
local helper = dofile("spec/helper.lua")

local function cache(store, overrides)
  local ns = helper.loadModules({ "RaidInspector/Cache.lua" })
  local config = { schemaVersion = 1, staleSeconds = 7200, pruneSeconds = 2592000 }
  for k, v in pairs(overrides or {}) do config[k] = v end
  return ns.Cache.new(store or {}, config), ns
end

local function record()
  return { name = "Tester", slots = { [1] = { itemLink = "item:1" } } }
end

describe("Cache storage", function()
  it("stores and retrieves a record", function()
    local c = cache()
    c:put("A", record(), 100)
    assert.equals("Tester", c:get("A").name)
  end)

  it("returns nil for an unknown guid", function()
    assert.is_nil(cache():get("nope"))
  end)

  it("stamps the store with the schema version", function()
    local store = {}
    local c = cache(store)
    c:put("A", record(), 100)
    assert.equals(1, store.schemaVersion)
  end)
end)

describe("Cache staleness", function()
  it("is fresh inside the stale window", function()
    local c = cache(nil, { staleSeconds = 100 })
    c:put("A", record(), 100)
    assert.falsy(c:isStale("A", 150))
  end)

  it("is stale past the window", function()
    local c = cache(nil, { staleSeconds = 100 })
    c:put("A", record(), 100)
    assert.truthy(c:isStale("A", 300))
  end)

  it("treats a missing record as stale", function()
    assert.truthy(cache():isStale("nope", 100))
  end)
end)

describe("Cache pruning", function()
  it("drops records past the prune window", function()
    local c = cache(nil, { pruneSeconds = 100 })
    c:put("old", record(), 100)
    c:put("new", record(), 500)
    local dropped = c:prune(550)
    assert.equals(1, dropped)
    assert.is_nil(c:get("old"))
    assert.truthy(c:get("new"))
  end)

  it("keeps everything when nothing is old enough", function()
    local c = cache(nil, { pruneSeconds = 1000 })
    c:put("A", record(), 100)
    assert.equals(0, c:prune(200))
  end)
end)

describe("Cache schema migration", function()
  -- Discarding beats migrating: a half-migrated cache renders as confident data
  -- that was derived under different rules.
  it("discards a store written by an older schema", function()
    local store = { schemaVersion = 0, players = { A = record() } }
    local c = cache(store)
    c:migrate()
    assert.is_nil(c:get("A"))
    assert.equals(1, store.schemaVersion)
  end)

  it("keeps a store written by the current schema", function()
    local store = {}
    local c = cache(store)
    c:put("A", record(), 100)
    c:migrate()
    assert.truthy(c:get("A"))
  end)
end)
```

- [ ] **Step 2: Run the tests and verify they fail**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Cache"
```

Expected: eleven failures.

- [ ] **Step 3: Write the implementation**

Create `RaidInspector/Cache.lua`:

```lua
local addonName, ns = ...

local Cache = {}
ns.Cache = Cache

local Instance = {}
Instance.__index = Instance

function Cache.new(store, config)
  store.players = store.players or {}
  return setmetatable({ store = store, config = config }, Instance)
end

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
-- different rules, which is the failure this whole design is built to avoid.
function Instance:migrate()
  if self.store.schemaVersion ~= self.config.schemaVersion then
    self.store.players = {}
    self.store.schemaVersion = self.config.schemaVersion
  end
end
```

- [ ] **Step 4: Run the tests and verify they pass**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Cache"
```

Expected: `11 passed, 0 failed`.

- [ ] **Step 5: Commit**

```powershell
git add RaidInspector/Cache.lua spec/Cache_spec.lua
git commit -m "feat: Cache with staleness, pruning and discard-on-schema-change"
```

---

### Task 4: Hydrator, Scanner, Roster and Core

**Files:**
- Create: `RaidInspector/Hydrator.lua`
- Create: `RaidInspector/Scanner.lua`
- Create: `RaidInspector/Roster.lua`
- Create: `RaidInspector/Core.lua`
- Create: `RaidInspector/RaidInspector.toc`
- Create: `tools/deploy.ps1`

These four modules talk to the WoW API and cannot be unit tested outside the game. They are
deliberately kept thin: every decision that can be made without the API already lives in
`ScanQueue`, `Rules` or `Evidence`. What remains here is plumbing.

**Behaviour each module must implement**, drawn from sections 3 and 7 of the spec:

**`Roster`** — tracks group members on `GROUP_ROSTER_UPDATE`, exposing GUID, name, class and
unit token. Fires callbacks when players join or leave so the queue stays in step.

**`Hydrator`** — takes a parsed link and produces the item record plus its evidence:
- waits for the item with `Item:CreateFromItemLink():ContinueOnItemLoad()`
- a hydration timeout marks the slot `unknown` and leaves it for the next pass; without one a
  slot can sit in `hydrating` forever on an item the server never resolves
- socket count from `C_Item.GetItemStats`, summing the `EMPTY_SOCKET_*` keys — which count
  sockets present, not sockets empty
- `setID` from the 16th return of `C_Item.GetItemInfo`
- upgrade track through `UpgradeTrackAdapter` on `C_TooltipInfo.GetHyperlink`
- evidence flags reflect what actually came back, never optimism

**`Scanner`** — the event layer:
- pauses on `PLAYER_REGEN_DISABLED` and `ENCOUNTER_START`, resumes on `PLAYER_REGEN_ENABLED`
  and `ENCOUNTER_END`
- pauses while Blizzard's `InspectFrame` is shown
- prefilters with `CanInspect` and `UnitInRange`, feeding `ScanQueue:setRangeHint`
- issues `NotifyInspect` at no more than the configured budget
- on `INSPECT_READY`, resolves the unit with `UnitTokenFromGUID` and **immediately verifies
  `UnitGUID(unit) == guid`**, because that API is documented as unstable
- harvests all sixteen slots inside the handler, since the data is only valid until the next
  `NotifyInspect` or `ClearInspectPlayer`
- harvests foreign `INSPECT_READY` events too, which is free coverage
- calls `ClearInspectPlayer()` only after its own request and only while `InspectFrame` is
  closed, because a foreign requester still needs the data
- counts slots returned and passes that to `ScanQueue:onSuccess`
- treats a request with no reply inside the timeout as `onTimeout`

**`Core`** — wiring, SavedVariables binding, and slash commands:
- `/ri` toggles the report
- `/ri scan` runs a priority pass: flush, reset backoffs, requeue everyone in range
- `/ri report` prints findings per player to chat, grouped, with the coverage line
- `/ri debug` prints queue state per player

- [ ] **Step 1: Write the TOC**

Create `RaidInspector/RaidInspector.toc`. Load order matters: pure modules first, wiring last.

```
## Interface: 120007
## Title: Raid Inspector
## Notes: Live raid gear inspection.
## SavedVariablesPerCharacter: RaidInspectorDB

Version.lua
Data\Version.lua
Data\Enchants.lua
Data\Gems.lua
Data\Embellishments.lua
Policy\Slots.lua
Policy\Season.lua
LinkParser.lua
Evidence.lua
UpgradeTrackAdapter.lua
DataVersion.lua
Rules.lua
ScanQueue.lua
Cache.lua
Roster.lua
Hydrator.lua
Scanner.lua
Core.lua
```

- [ ] **Step 2: Write the four modules**

Implement the behaviour above. Keep each file focused; if `Scanner.lua` grows past roughly 200
lines, something that belongs in `ScanQueue` has leaked into it.

- [ ] **Step 3: Write the deploy script**

Create `tools/deploy.ps1`, mirroring `tools/deploy-spike.ps1` but for `RaidInspector/`.

- [ ] **Step 4: Verify the whole suite still passes**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

The new modules have no unit tests, but they must not break the existing ones.

- [ ] **Step 5: Deploy and verify in game**

```powershell
powershell -ExecutionPolicy Bypass -File tools\deploy.ps1
```

In game, in a group or raid:

1. `/reload`
2. `/ri debug` — every group member should appear, initially `unseen`
3. Wait roughly a minute, then `/ri debug` again — states should be advancing
4. `/ri report` — findings per player, with the coverage line
5. Open Blizzard's own inspect window on someone; `/ri debug` should show the queue paused
6. Enter combat; the queue should pause and resume afterwards

**What to check specifically**, because these are the assumptions the spike could not settle:

- How many passes does a player actually need before every slot is confirmed? The spike showed
  a single inspect returns 2 to 15 of 16 slots, but not how fast that converges.
- Does the coverage line ever reach a sensible number, or do players sit in `unreachable`?
- Do the findings match what you can see by inspecting someone by hand?

- [ ] **Step 6: Commit**

```powershell
git add RaidInspector tools/deploy.ps1
git commit -m "feat: runtime layer -- roster, hydrator, scanner and wiring"
```

---

## What remains after this plan

**Part 5: the UI.** The grid with its summary column, the detail panel and the coverage bar.
Everything it needs is in place by then: `Rules` produces findings, `ScanQueue` produces
coverage, and `Cache` produces staleness.
