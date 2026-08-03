# Raid Inspector — Design

**Date:** 2026-08-03
**Status:** Approved after review by Fable and Codex; part 1 implemented and merged
**Target:** World of Warcraft retail, Midnight (12.0.7), season 1

---

## 1. Purpose and scope

A private WoW addon that lets a raid leader see the gear status of every raid member on one
screen: item level, missing or weak enchants, empty sockets, upgrade tracks, tier pieces and
embellishments. Comparable to what the WoW Audit website shows, but entirely in game.

This spec describes the **live in-raid view**. A more extensive audit or export mode is a
possible follow-up and is out of scope here.

### Checks in version 1

1. Item level — average and per slot; empty gear slots
2. Missing enchants on enchantable slots
3. Enchant and gem quality (Silver versus Gold)
4. Empty sockets, and slots that could take a socket but have none
5. Upgrade track per item (Myth/Hero/Champion/Veteran plus rank) and upgrades remaining
6. Tier pieces worn (x/5) and embellishments used (max 2)

---

## 2. Locked-in decisions

| Decision | Choice | Reason |
|---|---|---|
| Data source | In-game inspect only | Must work on players without the addon, including pugs |
| ID tables | Generated from wago.tools DB2 exports | Maintaining them by hand is error-prone busywork every patch |
| Main view | Grid of player × slot, plus a summary column | Maximum density; the summary column makes it actionable |
| Scan strategy | Opportunistic background queue with a persistent cache, plus a manual "Scan now" | The only approach that genuinely solves the range limit |
| Socket policy | A missing addable socket is a warning | Counts as a missed optimisation, the way WoW Audit treats it |

Inspect-only carries two permanent costs that have been accepted: **no coverage of players
out of range**, and **no freshness signal** — no event reports that another raid member has
changed something. The `source` field in the data model keeps the door open for an optional
addon comm channel later without a model change.

---

## 3. Verified platform constraints

These drive the entire design. Items marked *(measured)* were established by the spike of
2026-08-03; see `docs/superpowers/spike-results.md`.

- **Inspect requires `CanInspect(unit)` and interact distance (~28 yd).** Players further
  away cannot be scanned.
- **`CanInspect` does not prove range.** It means "this kind of unit may be inspected", not
  "this request will succeed".
- **`UnitInRange` is not inspect range.** It returns 40 yd (25 yd for Evokers) and only for
  group members. It is a coarse prefilter that structurally lets through players standing at
  28–40 yd who cannot be inspected. See section 7 for how the queue absorbs that.
- **The server throttles around 6 requests per 10 seconds.** Above that budget requests are
  *silently dropped* — no `INSPECT_READY` fires. A timeout with backoff is required, not
  just a timer. The budget is shared with other addons and with the user's manual inspects.
  This number is community-measured rather than documented; the addon treats it as an
  assumption with headroom.
- **There is one global inspect slot and the addon does not own it.** `NotifyInspect` cancels
  in-flight inspects from Blizzard's own `InspectFrame` and from other addons, and
  `INSPECT_READY` also fires for requests the addon did not make.
- **`UnitTokenFromGUID` is explicitly unstable.** The token must be resolved at event time
  and immediately verified with `UnitGUID(unit) == guid`.
- **`CheckInteractDistance` has been blocked in combat for insecure code since 10.2.0.**
  Do not use it.
- **Item data is asynchronous.** `C_Item.GetItemInfo`, `C_Item.GetDetailedItemLevelInfo`,
  `C_Item.GetItemStats` and tooltip queries return `nil` or empty for items not in the local
  client cache — normal on a fresh client and on patch day.
- **Tooltip data can be incomplete, and `hasDynamicData` does not help** *(measured)*. The
  field was absent on all 184 recorded items. Completeness has to be inferred from the lines
  themselves, not from a flag.
- **An inspect often returns only part of the slots** *(measured)*. Across 22 captures the
  slots returned were 15, 15, 15, 15, 12, 12, 11, 11, 11, 10, 10, 7, 7, 6, 6, 4, 4, 3, 3, 3,
  2, 2 — median about 8, where a geared raider has 15 or 16. `GetInventoryItemLink` returned
  `nil` for the rest. The problem is not just missing *payload* within a link but **entirely
  missing slots**.
- **Socket count is not in the item link.** The link only carries the gems present.
  `C_Item.GetItemStats` and `C_Item.GetItemNumSockets` agreed on all 184 items *(measured)*,
  so either works.
- **The item link colour prefix is `|cnIQ4:`** *(measured)*, not `|cffa335ee`. Matching on
  the colour segment breaks; match on `|Hitem:`.
- **Modifier values can be negative** *(measured)*, and a non-numeric field — the crafter
  GUID — can follow the modifiers.
- **`C_Item.GetItemInfo` is the namespaced form**; its 16th return value is still `setID`.
  12.0 added an 18th return value, `itemDescription`.
- **There is no first-party API for the upgrade track of an inspected item.**
  `C_ItemUpgrade.GetItemUpgradeInfo` only works in the vendor context for your own items.
  `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` exists and holds `Upgrade Level: %s %d/%d`
  *(measured)*; the line appears verbatim in inspected tooltips, on 106 of 184 items.
- **12.0 tightened the addon restriction framework** (Secret values, `C_RestrictedActions`).
  Inspect APIs are not on the list today, but Blizzard is actively narrowing addon behaviour
  in combat.

### Midnight-specific facts

- Enchants have **two quality tiers: Silver and Gold**. Bronze no longer exists. The War
  Within model of rank 1/2/3 does not apply.
- **Gems are likewise two-tier** (Silver/Gold); raw gems now carry quality too.
- **The enchantable slots changed**: cloak and bracers dropped out, helm and shoulders came
  back. Current: helm, shoulders, chest, legs (spellthread via Tailoring), boots, both rings,
  weapons. Confirmed against real data: neck, waist, wrist, trinkets, back and off-hand
  showed zero enchants across 83 observations.
- **Gloves can carry an enchant ID without being enchantable** *(measured)* — almost
  certainly engineering tinkers, which occupy the same field. Never derive the enchantable
  list from observed data.
- Tier slots are unchanged: helm, shoulders, chest, hands, legs.
- Embellishments: at most 2, only on crafted gear; crafted gear cannot be catalysed.

---

## 4. Architecture

One dependency direction. `Cache` and `Data` are leaves.

```
Scanner ──▶ LinkParser ──▶ Hydrator ──▶ Rules ──▶ UI
 (async)      (pure)        (async)     (pure)
    │                          │           │
    ├──────▶ Cache             │           └──▶ Policy
    │          ▲ (read only)   │
    │          └───────────────┘           └──▶ Data
    └──▶ UpgradeTrackAdapter (below Hydrator)
```

`Hydrator` **reads** from `Cache` but never writes to it: only raw data is persisted
(section 11), derived values never.

```
RaidInspector/
  RaidInspector.toc
  Core.lua                 -- namespace, event dispatch, slash commands, combat gating
  Roster.lua               -- group roster: GUID, name, realm, class, spec
  Scanner.lua              -- inspect queue: budget, tiers, timeouts, contention
  LinkParser.lua           -- item link -> raw table                    [PURE]
  Hydrator.lua             -- waits on the item cache; ilvl, sockets, setID
  UpgradeTrackAdapter.lua  -- tooltip line -> track/rank; locale and build sensitive
  Evidence.lua             -- which evidence was complete per read       [PURE]
  Rules.lua                -- gear + evidence + policy -> findings       [PURE]
  DataVersion.lua          -- degradation on patch version               [PURE]
  Cache.lua                -- SavedVariables, schema version, TTL, pruning
  UI/Grid.lua              -- grid, summary column, coverage bar
  UI/Detail.lua            -- per-player detail panel
  Policy/
    Slots.lua              -- enchantable and socketable slots this season
    Season.lua             -- which enchant/gem tier is current, current tier set IDs
  Data/                    -- GENERATED, do not hand-edit
    Enchants.lua           --   enchantID -> { quality, tier }   FULL HISTORY
    Gems.lua               --   gemID -> { quality, tier }       FULL HISTORY
    UpgradeTracks.lua      --   bonusID -> { track, rank, max }
    Embellishments.lua     --   bonusID -> { name }
    Version.lua            --   patch version and build of generation
  tools/generate.mjs       -- wago.tools CSV -> Data/*.lua
  tools/csv/               -- checked-in CSV snapshots, for reproducible generation
  spec/                    -- tests, run under a bundled Lua 5.1 interpreter
```

### Responsibilities

**`LinkParser`** — pure. Item link string in; `itemID`, `enchantID`, `gemIDs`, `bonusIDs` and
modifier pairs out. Touches no WoW API, holds no state, fully testable outside the game.

**`Hydrator`** — the asynchronous bridge. Waits with
`Item:CreateFromItemLink():ContinueOnItemLoad()` until the item is loaded, then fills in item
level, socket count and `setID` from `C_Item.GetItemInfo`. Always also produces an
`Evidence` record: which sources were complete.

**`UpgradeTrackAdapter`** — separate from `Hydrator` because tooltip parsing is locale and
build sensitive and has its own failure path. Returns `{ track, rank, max }` or an explicit
`unknown`, never a guess.

**`Evidence`** — pure. Records per read which sources were complete. Without this layer
`Rules` silently turns missing data into bad gear; that is the core of section 6.

**`Rules`** — pure. Takes a hydrated record, its evidence, `Policy` and `Data`; returns a flat
list of findings. Knows nothing of events or frames. The UI renders findings only and never
touches a bonus ID.

**`Policy`** — hand-maintained, deliberately not generated, and split because it holds two
kinds of judgement with different validation paths. `Slots.lua`: which slots are enchantable
and socketable this season. `Season.lua`: which enchant and gem tier counts as current, and
which set IDs form the current tier. `Data` stays purely mechanical — ID to fact, no
seasonal judgement.

---

## 5. Data model

Only raw data is persisted. Everything derived is recomputed on load — otherwise a
conclusion from before a data update lives on silently beside the new tables.

```lua
PlayerRecord = {
  guid, name, realm, class, specID,
  source     = "inspect",   -- room for "comm" without a model change
  status,                   -- see the state machine in section 6
  firstSeen, lastSeen, scannedAt,
  passCount, failCount,
  slots = { [INVSLOT_HEAD] = SlotRecord, ... },
}

SlotRecord = {
  itemLink,        -- raw; the source of truth
  fingerprint,     -- hash of the link
  reads = {        -- per evidence source: how often seen complete at this fingerprint
    link      = { count, lastAt },
    sockets   = { count, lastAt },
    tooltip   = { count, lastAt },
    itemData  = { count, lastAt },
  },
}

SlotEvidence = {   -- per read, not persisted
  linkComplete,    -- link carried enchant/gem payload
  socketsKnown,    -- socket count retrieved, not nil
  tooltipComplete, -- tooltip delivered with its expected lines
  itemLoaded,      -- ContinueOnItemLoad succeeded
}

Finding = { slot, kind, severity, state, detail }
```

`kind` ∈ `missing_item`, `missing_enchant`, `low_enchant`, `outdated_enchant`,
`empty_socket`, `missing_socket`, `low_gem`, `outdated_gem`, `upgrades_left`,
`tier_incomplete`, `embellishments_missing`.

`severity` ∈ `error`, `warn`. `state` ∈ `ok`, `bad`, `unknown`, `stale`.

The sixteen checked slots: head, neck, shoulders, back, chest, wrist, hands, waist, legs,
feet, finger 1, finger 2, trinket 1, trinket 2, main hand, off hand. Shirt, tabard and
profession tools are excluded — the latter are not part of the inspectable paper doll and
have no bearing on raid performance.

---

## 6. Trust model

This is the most important rule in the whole addon. If the grid ever turns red on data that
simply had not arrived, the raid leader calls someone out wrongly and the addon only needs
that to happen once to be uninstalled.

### The rule

- A **positive** finding ("there is a Gold enchant on it") may be shown immediately. It
  cannot arise from missing data.
- A **negative** finding only becomes `bad` when **all four** of these hold:
  1. the same `fingerprint` across at least two reads;
  2. the evidence sources that finding needs were complete in at least two of those reads;
  3. those two reads are at least **10 seconds** apart;
  4. the generated data is valid for the running patch version (section 10).
- An unrecognised bonus ID pattern is `unknown`, **never** "no track" or "fully upgraded".
- Data older than the TTL becomes `stale` and is visually dimmed — never rendered
  identically to a fresh scan.

Condition 2 is what the fingerprint alone does not cover: the link can be identical *and*
complete twice while the tooltip line was missing both times or the socket count was `nil`
both times. The fingerprint counter would then report two confirmations for a finding that
never had evidence. Condition 3 catches two rapid, identically incomplete reads.

### Evidence per finding

| `kind` | required evidence |
|---|---|
| `missing_item` | `itemLoaded` for the other slots (proves the pass carried data) |
| `missing_enchant` | `linkComplete` |
| `low_enchant` / `outdated_enchant` | `linkComplete` + enchant ID known in `Data/Enchants` |
| `empty_socket` | `linkComplete` + `socketsKnown` |
| `missing_socket` | `socketsKnown` |
| `low_gem` / `outdated_gem` | `linkComplete` + gem ID known in `Data/Gems` |
| `upgrades_left` | `tooltipComplete`, or bonus ID recognised in `Data/UpgradeTracks` |
| `tier_incomplete` | `itemLoaded` for all five tier slots |
| `embellishments_missing` | `linkComplete` for all crafted items |

`Scanner` increments the evidence counters at harvest time, right after parsing and
hydrating. When the fingerprint changes, every counter for that slot resets to zero.

### Known-but-outdated is not unknown

A raider wearing a War Within enchant must be **yellow**, not grey. That is why
`Data/Enchants.lua` and `Data/Gems.lua` carry the **full history** with a tier tag, and
`Policy/Season.lua` decides which tier counts as current. A known but outdated ID then yields
an `outdated_enchant` warning, and `unknown` stays reserved for what genuinely is not
recognised. The DB2 exports contain everything already; the extra size is negligible.

### Per-player state machine

```
unseen ──▶ queued ──▶ inflight ──┬─▶ hydrating ──▶ partial ──▶ confirmed ──▶ stale
   ▲          ▲                  │       │            │            │           │
   │          │                  │       └──▶ unknown │            │           │
   │          │       timeout (backoff, retry)        │            │           │
   │          └──────────────────┴─────────────────────            │           │
   │                                                    reconfirmation         │
   │                                                                           │
   └───◀─── unreachable ◀─── 5 consecutive timeouts                            │
              │                                                                │
              └──▶ back to queued on UNIT_IN_RANGE_UPDATE or after a 60s reprobe
```

"Done" does not exist. A player stays in rotation until every slot is confirmed, then moves
to a slow reconfirmation cadence. **`unreachable` is never final**: the player returns to the
queue as soon as `UNIT_IN_RANGE_UPDATE` fires, and otherwise through a slow reprobe every 60
seconds. Without that exit, the healer who was fetching water when the addon loaded stays
grey all night.

---

## 7. Scanner

### Budget and queues

At most 6 requests per 10 seconds; the addon holds to **5 per 10 s** because the budget is
shared with other addons and with manual inspects.

Because `UnitInRange` passes players up to 40 yd while inspect stops at ~28 yd, a naive
single queue would structurally burn budget on unreachable players. Hence three queues with
a fixed share of the budget:

| Queue | Contents | Share |
|---|---|---|
| A — warm | `CanInspect` true, `UnitInRange` true, no recent timeout | ≥ 70% |
| B — reconfirmation | `confirmed`, cadence expired | ~20% |
| C — cold | recent timeout or `unreachable` | ≤ 10% |

Queue C must never consume more than its share. Without that ceiling a handful of players at
30–40 yd — who pass `UnitInRange` but fail inspect — can starve every useful scan of nearby
raid members.

| Value | Default |
|---|---|
| Request budget | 5 per 10 s |
| Timeout per request | 3 s |
| Backoff | base 5 s, ×2 per consecutive timeout, ceiling 60 s (5/10/20/40/60) |
| Retry cap per player per pass | 3 |
| `unreachable` after | 5 consecutive timeouts |
| Reprobe of `unreachable` | every 60 s, plus immediately on `UNIT_IN_RANGE_UPDATE` |
| Reconfirmation cadence after `confirmed` | every 10 min |
| Minimum interval between confirming reads | 10 s |

**The arithmetic.** At 5 requests per 10 s the ceiling is 0.5 inspects per second. One round
over 30 players therefore takes at least 60 seconds, and the two passes the trust model
demands at least two minutes — in the ideal case without combat pauses, competing addons or
timeouts.

Those two minutes are **too optimistic in practice**, because a successful inspect rarely
returns every slot (section 3, measured: median about 8 of 16). A player is only confirmed
once every slot has two complete reads, and a pass that returned 3 of 16 slots only
contributes to three slots. Expect several passes per player before the grid is meaningfully
green.

Three requirements follow from that:

- **Every pass records how many slots it returned.** A pass with 2 slots is barely evidence;
  a pass with 15 is. That number belongs with the evidence, not just in the log.
- **A missing slot is not an empty slot.** `GetInventoryItemLink` returning `nil` means "this
  pass did not know", not "the player wears nothing here". Only a substantially complete pass
  may produce `missing_item` evidence.
- **The reconfirmation cadence applies per slot, not per player.** Otherwise slots that
  happened never to come back stay unconfirmed forever while the player counts as
  `confirmed`.

Reconfirmation itself is cheap: 30 requests per 10 minutes is 10% of the budget. The UI must
show the build-up phase explicitly (section 9), or the addon will look broken.

### Manual scan

`/ri scan` and the button in the UI perform one priority round: flush the queue, reset all
backoffs, place everyone who currently passes `CanInspect` and `UnitInRange` into queue A,
and report coverage afterwards. Intended for the moment just before the pull, when the raid
is stacked and coverage is at its best.

### Contention

- Every `INSPECT_READY` is matched by GUID against the addon's own outstanding request.
- Events from other addons **are** harvested — that is free coverage.
- `ClearInspectPlayer()` is called **only** after an inspect the addon started itself, and
  only when Blizzard's `InspectFrame` is closed. Never after reading a foreign event: the
  requester still needs that data.
- The queue pauses while `InspectFrame` is visible.

### Harvesting

`GetInventoryItemLink(unit, slot)` is only valid until the next `NotifyInspect` or
`ClearInspectPlayer`. All sixteen slots are therefore read inside the `INSPECT_READY`
handler. The unit token is resolved at that moment with `UnitTokenFromGUID` and immediately
verified with `UnitGUID(unit) == guid` — raid indices shift between request and reply, and
the API is documented as unstable.

`GetInspectSpecialization(unit)` is only valid after `INSPECT_READY`; record it there.

`C_PaperDollInfo.GetInspectItemLevel(unit)` serves as a **rough** cross-check on the computed
average, with tolerance. An exact comparison is unreliable as long as the addon's own maths
does not replicate Blizzard's weighting for two-handers, off-hands and empty slots; a large
difference is a signal, a small one is not.

### Combat

The scanner hard-pauses on `PLAYER_REGEN_DISABLED` and `ENCOUNTER_START`, and resumes on
`PLAYER_REGEN_ENABLED` and `ENCOUNTER_END`. Scanning during an encounter achieves nothing and
Blizzard is actively tightening addon behaviour in combat.

---

## 8. Rules and policy

### Curated lists (`Policy/`, Midnight season 1)

| List | Slots |
|---|---|
| Enchantable | head, shoulders, chest, legs (spellthread), feet, finger 1, finger 2, main hand, off-hand **weapon** |
| Socket addable | head, wrist, waist |
| Tier | head, shoulders, chest, hands, legs |

Shields and held-in-off-hand items are not enchantable; only an off-hand *weapon* counts. The
current tier set IDs live in `Policy/Season.lua` alone — not in `Data/` as well, because two
sources for the same fact are guaranteed to drift apart.

### Severity

**Error** — empty gear slot; missing enchant on an enchantable slot; empty socket.

**Warning** — Silver instead of Gold enchant or gem; enchant or gem from a previous season;
socketable slot without a socket; upgrades remaining; tier below 5/5; fewer than 2
embellishments.

**Unknown** — bonus ID pattern not recognised; item not yet loaded from the cache; required
evidence missing; generated data invalid for this patch version.

### Edge cases that would otherwise produce false findings

- A two-handed weapon makes an empty off-hand **correct**. No finding.
- Crafted gear has **no** upgrade track. Do not report "0 upgrades remaining".
- The track denominator varies per track and per season. Hardcoding `/6` goes wrong.
- Empty sockets = total sockets − gems in the link. The `EMPTY_SOCKET_*` keys from
  `C_Item.GetItemStats` mean "there is a socket here", **not** "this socket is empty" — the
  key name is misleading and must not be taken literally.
- Gloves can carry an enchant ID (engineering tinkers) without being enchantable. The
  enchantable list is curated, never derived from observation.

### Sources per check

| Check | Primary source | Fallback / cross-check |
|---|---|---|
| Item level | `C_Item.GetDetailedItemLevelInfo` | `C_PaperDollInfo.GetInspectItemLevel`, rough |
| Enchant | `enchantID` from the link | — |
| Enchant quality | `Data/Enchants.lua` + `Policy/Season.lua` | — |
| Socket count | `C_Item.GetItemStats` | `C_Item.GetItemNumSockets`, verified equivalent |
| Gems | `gemIDs` from the link | — |
| Upgrade track | `C_TooltipInfo.GetHyperlink` via `UpgradeTrackAdapter` | `Data/UpgradeTracks.lua` |
| Tier | `setID` from `C_Item.GetItemInfo` (16th return) | — |
| Embellishments | bonus IDs from the link | — |

The tooltip is deliberately the **primary** source for the upgrade track: it survives a
season rollover with no maintenance at all, whereas bonus IDs are reissued every season. The
pattern is built from `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` (`Upgrade Level: %s %d/%d`) so it
also works on a non-English client. When building the Lua pattern: escape magic characters,
turn `%s` into a lazy capture (track names can contain spaces) and `%d` into `(%d+)`.

---

## 9. UI

One scroll frame with up to thirty rows. Per row: class-coloured name, average ilvl, sixteen
slot cells, and on the right a summary column with the count and severity of the findings.
Sorted on that column by default.

- Cells are textures from a single frame pool, with one shared `OnEnter`/`OnLeave` driving
  the shared `GameTooltip`. No `FontString` per cell.
- Only the row whose data just arrived is redrawn. The grid is never rebuilt wholesale per
  event.
- The four cell states are distinguished by **shape as well as colour**. Red-green alone is
  unreadable for colour-blind users.
- Class colour in the name and severity colour in the cells compete for attention; the cells
  are the dominant channel and the name colour stays muted.
- Coverage is permanently visible at the top. During the build-up phase explicitly as such:
  *"Scanning — 12/30 confirmed"*, and afterwards *"21/30 scanned — 9 out of range: <names>"*.
- Fresh `unknown` must never sort below stale `bad`; the age of the last fresh scan is
  visible per row.
- Clicking a row or cell opens `UI/Detail.lua` with the full slot-by-slot breakdown.

---

## 10. Data generator

`tools/generate.mjs` fetches the DB2 CSV exports from wago.tools (ItemSparse, ItemBonus,
SpellItemEnchantment and relatives) and writes `Data/*.lua`. One command per patch. The CSV
snapshots used are checked into `tools/csv/` so a generation run is reproducible.

Access verified: `https://wago.tools/db2/SpellItemEnchantment/csv?build=12.0.7.68887` returns
543 KB of CSV, and the build number can be pinned.

- `Data/Version.lua` holds the **patch version** and the build number at generation time.
- **Degradation keys off the patch version, not the build number.** Build numbers rise almost
  weekly through hotfixes that touch no items; degrading on build would put the addon in a
  crippled state for most of every season, the exact opposite of what the safeguard is for.
  Rule: a newer **patch version** than the data → hard degrade to `unknown` for everything
  that depends on `Data/`. A newer **build** within the same patch → a soft "data may be
  outdated" banner, otherwise business as usual.
- `Policy/` is **not** generated. Which enchants count as current this season and which slots
  can take a socket is curation, not derivable from DB2.
- `Enchants.lua` must also include `SpellItemEnchantment` entries originating from
  **Tailoring and Leatherworking**, not only Enchanting — spellthreads and leg armor kits
  occupy the same enchantID field in the link.
- Existing precedent for the pipeline: [WowDbScripts](https://github.com/thespags/WowDbScripts).

**Maintenance risk, stated explicitly.** Every season the enchant IDs, gem IDs, track bonus
IDs, set IDs, embellishment IDs and track denominators change, and the wago.tools CSV schema
may shift and break the generator. The mitigations are: patch-version-bound degradation, full
historical tables so old gear stays recognised, and keeping the generated surface as small as
possible — `setID` instead of a tier item table, and the tooltip instead of the track table.

---

## 11. Persistence

- SavedVariables, keyed on GUID. Size is a non-issue: thirty players × sixteen slots of raw
  links is a few hundred kilobytes at most.
- Schema version in the file. On a version mismatch the cache is discarded rather than
  migrated.
- Pruning on login: records whose `lastSeen` is older than **30 days** expire.
- Data older than **2 hours** becomes `stale`.
- All derived values are recomputed on load, never persisted. That means rehydrating up to
  480 links at login; that goes **through the same queue**, not in a single frame.
- Persisted data is only ever shown as `stale`, with its age attached.

---

## 12. Tests

`LinkParser`, `Evidence`, `Rules`, `UpgradeTrackAdapter` and `DataVersion` run under a
bundled **Lua 5.1.5** interpreter in `tools/lua/`, without a WoW client. Lua 5.1 rather than
a newer version on purpose: WoW runs modified PUC Lua 5.1, and the dangerous class of bug is
syntax that 5.4 accepts and 5.1 rejects at file load — `goto`, `//`, native bitwise
operators, `table.unpack`. Those pass locally and break the moment the file loads in game.
Testing under 5.1 makes them impossible rather than "carefully avoided".

The harness deliberately does **not** shim WoW globals such as `strsplit`, `format` or
`tinsert`. Their absence is what enforces purity.

- **`LinkParser`** — the test corpus is drawn from real Midnight inspects, weighted towards
  crafted, embellished, socketed and tier links. An item link is not a fixed column split but
  a nested structure of length-prefixed lists followed by key/value modifier pairs. Naive
  index parsing works fine on dropped gear and breaks precisely on the items checks 3 and 6
  are about. The corpus is refreshed each season.
- **`Evidence`** — explicitly tested on the scenario that justifies the whole model: two
  reads with an identical fingerprint but missing tooltip or socket data both times must not
  produce `bad`.
- **`Rules`** — table-driven: every `kind`, every `severity`, the four conditions from
  section 6, and the distinction between known-but-outdated (`warn`) and genuinely unknown
  (`unknown`).
- **`Scanner`** and **`UI`** stay thin enough for manual verification in game.

---

## 13. Out of scope

Not obtainable through inspect, recorded deliberately so it does not creep back in:

- Great Vault progress, crests earned, raid kills — those come from Blizzard's Armory API.
- Temporary weapon enchants and oils on other players; `GetWeaponEnchantInfo` only works for
  yourself and temporary enchants are not in the item link.
- Consumables.
- Profession tools.
- A freshness signal: no event reports that another raid member has re-gemmed.

Out of scope for version 1 but deliberately not ruled out:

- An addon comm channel for complete, immediate data from raid members who do have the addon.
  The `source` field is already in place for it.
- An audit and export mode outside the raid.

---

## 14. Open questions

The spike of 2026-08-03 (12.0.7, build 68887) answered most of them; the results are in
`docs/superpowers/spike-results.md`. Answered and folded into this spec:

- Gems are two-tier (Silver/Gold), like enchants.
- Spellthread on legs occupies the ordinary `enchantID` field.
- Profession tools are out of scope.
- `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` exists and reads `Upgrade Level: %s %d/%d`; the line
  appears verbatim in inspected tooltips.
- `C_Item.GetItemStats` and `C_Item.GetItemNumSockets` returned identical numbers on 184
  items; the choice between them does not matter.
- A held-in-off-hand item carries no enchant, as assumed.
- Shoulders are enchantable in Midnight (six recipes, 4 of 8 observed); the policy is correct.
- `hasDynamicData` is never present and cannot be used to judge tooltip completeness.

Still open:

1. **Shields.** No shield appeared in the sample. The assumption stands: off-hand *weapons*
   require an enchant, shields do not.
2. **How many passes are realistically needed** before a player is fully confirmed? The spike
   shows a single inspect can return 2 to 15 slots, but not how quickly that converges under
   repeated scanning. To be measured with the scanner prototype in part 4.
