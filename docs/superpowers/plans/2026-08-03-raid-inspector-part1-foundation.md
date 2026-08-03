# Raid Inspector — Implementation plan, part 1: foundation

> **Status: EXECUTED and merged.** All eight tasks are complete and the suite is green.
> This document is kept as the record of what was built and why.
>
> The code bodies that were originally written out step by step in this plan now exist as
> real files in the repository. They are referenced rather than duplicated here, so there is
> a single source of truth. Use `git log` for the step-by-step history.

**Goal:** Build the pure core of the addon — item link parser, evidence bookkeeping, policy
and rules — plus a throwaway spike that answers, in game, the three uncertain assumptions the
rest of the design rests on.

**Architecture:** Modules are plain Lua files that populate a shared table through the WoW
addon namespace (`local addonName, ns = ...`). `LinkParser`, `Evidence` and `Rules` touch no
WoW API and therefore run under a bare Lua 5.1 interpreter outside the game. The test harness
loads them with `loadfile` and passes the same two arguments WoW does, so the load shape is
identical.

**Tech stack:** Lua 5.1.5 (PUC, prebuilt binary in `tools/lua/`), a purpose-built minimal
test runner with no dependencies, PowerShell for orchestration.

## Why Lua 5.1 and not a newer interpreter

WoW runs modified PUC Lua 5.1. Testing under 5.4 — via wasmoon or busted — would leave one
class of bug invisible: syntax that 5.4 accepts and 5.1 rejects at *file load*, such as
`goto`, `//`, native bitwise operators and `table.unpack`. Those pass locally and break the
moment the file loads in game. A second class matters specifically here: 5.3+ uses 64-bit
integers while 5.1 uses doubles with a 53-bit mantissa, which would silently diverge in the
`Evidence` fingerprint hash — the value that decides whether two reads count as identical,
and therefore whether a finding may turn red.

Vendoring a 1 MB prebuilt interpreter removes the entire question instead of requiring
perpetual vigilance. The binary lives in `tools/lua/` and is checked in.

## Global constraints

- **Target runtime is Lua 5.1.** Forbidden throughout the addon code: `goto`, `//`, native
  bitwise operators (`&`, `|`, `~`, `<<`, `>>`), `\z` in strings, `table.unpack` (use
  `unpack`).
- **No WoW globals in pure modules.** `strsplit`, `format`, `tinsert`, `wipe` and relatives
  only exist in game. The test harness deliberately does **not** shim them; their absence is
  the purity check.
- **No `#` on tables with holes.** `gemIDs` is an array of four with possible gaps; count
  explicitly, never use `#`.
- **No assumptions about integer width.** All arithmetic stays below 2^53 so 5.1 doubles and
  5.4 integers produce the same result.
- **Target game version:** retail Midnight (12.0.7, build 68887).
- Addon folder and namespace: `RaidInspector`. LF line endings, UTF-8 without BOM.
- All source, comments, test names, documentation and commit messages in English.

## References

- Spec: `docs/superpowers/specs/2026-08-03-raid-inspector-design.md`
- Spike results: `docs/superpowers/spike-results.md`
- WoW AddOns folder on this machine:
  `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns`

---

### Task 1: Toolchain, test runner and repository skeleton — DONE

**Files:** `tools/lua/lua5.1.exe`, `tools/run-tests.lua`, `tools/test.ps1`,
`spec/helper.lua`, `spec/harness_spec.lua`, `RaidInspector/Version.lua`, `.gitattributes`,
`.gitignore`

**Interfaces:**
- `spec/helper.lua` exports `helper.loadModules(paths)`, returning a fresh namespace table
  after loading the given addon files into it.
- Global test functions `describe(name, fn)`, `it(name, fn)`, `before_each(fn)` and the
  callable assertion table `assert` with `.equals`, `.same`, `.truthy`, `.falsy`, `.matches`,
  `.is_nil`.

The interpreter was obtained from LuaBinaries. Note that `downloads.sourceforge.net` serves
an HTML interstitial instead of the archive; the working URL is
`https://master.dl.sourceforge.net/project/luabinaries/5.1.5/Tools%20Executables/lua-5.1.5_Win64_bin.zip?viasf=1`.

Two design points in the runner worth keeping:

- **Deep equality reports the diverging key path.** Findings are nested tables, and "they
  differ" is a useless failure message.
- **Writing a global is an error** once the DSL is set up. Accidentally creating a global is a
  classic WoW addon bug because you pollute the client's shared namespace; outside the game
  that is free to catch.

Globbing happens in PowerShell rather than Lua, because Lua 5.1 has no directory listing
without `luafilesystem`, which would need a C compiler. `tools/test.ps1` also pushes the
working directory to the repo root, since spec files use a relative `dofile("spec/helper.lua")`.

**Verification:** `powershell -ExecutionPolicy Bypass -File tools\test.ps1` → `4 passed, 0 failed`.

---

### Task 2: LinkParser — fixed fields — DONE

**Files:** `RaidInspector/LinkParser.lua`, `spec/LinkParser_spec.lua`,
`spec/fixtures/links.lua`

**Interfaces:** `ns.LinkParser.parse(link)` returns `nil` for unusable input, otherwise a
table with `itemID`, `enchantID`, `gemIDs` (array of four, 0 where empty), `gemCount`,
`suffixID`, `linkLevel`, `specID`, `itemContext`.

`gemCount` exists precisely because `#gemIDs` on an array padded with zeroes says nothing
meaningful — the global constraints forbid that pattern.

**Verification:** 7 tests, all passing.

---

### Task 3: LinkParser — bonus IDs and modifiers — DONE

**Files:** `RaidInspector/LinkParser.lua`, `spec/LinkParser_spec.lua`,
`spec/fixtures/links.lua`

**Interfaces:** the parse result gains `bonusIDs` (dense array) and `modifiers` (map of
modifier type to value). `_fields` disappears from the public shape.

This is where naive parsing breaks. The bonus ID list is length-prefixed, and behind it sits a
second length-prefixed list of pairs. Anyone parsing at fixed indices gets dropped gear right
and crafted gear wrong — exactly the items the enchant and embellishment checks are about.
Note that the modifier count counts *pairs*, not fields; that distinction is the most common
mistake with this format.

**Verification:** 14 LinkParser tests, 18 in total, all passing.

---

### Task 4: Spike addon for in-game verification — DONE

**Files:** `spike/RaidInspectorSpike/`, `tools/deploy-spike.ps1`,
`docs/superpowers/spike-results.md`

A throwaway addon whose only purpose is to measure what documentation cannot answer. Deployed
by copying rather than symlinking, because a symlink into `C:\Program Files (x86)` needs
elevated privileges.

The TOC interface number was not guessed: `.build.info` gives 12.0.7.68887, so `120007`.

**Outcome:** 22 captures, 184 slots. The full results are in
`docs/superpowers/spike-results.md`. The headline findings:

- `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` = `Upgrade Level: %s %d/%d`, present verbatim in
  inspected tooltips on 106 of 184 items.
- `C_Item.GetItemStats` and `C_Item.GetItemNumSockets` agreed on all 184 items.
- **184 of 184 real links parsed without a failure**, validating the synthetic fixtures the
  parser had been built against.
- Three things the real data revealed that could not have been reasoned out: the colour prefix
  is now `|cnIQ4:`, modifier values can be negative, and a crafter GUID can follow the
  modifiers as a non-numeric field.
- **Inspects are far less complete than the spec assumed**: median about 8 of 16 slots, with
  entire slots absent rather than merely missing payload. This fed back into section 7 of the
  spec.

The synthetic fixtures were then replaced with real Midnight links, and the suite still
passed — confirming the parser was right rather than merely self-consistent.

---

### Task 5: Evidence — DONE

**Files:** `RaidInspector/Evidence.lua`, `spec/Evidence_spec.lua`

**Interfaces:**
- `ns.Evidence.fingerprint(link)` returns a number identical under Lua 5.1 and 5.4, or `nil`.
- `ns.Evidence.newSlotRecord()` returns a fresh `SlotRecord` with empty counters.
- `ns.Evidence.record(slotRecord, link, evidence, now)` updates the counters.
- `ns.Evidence.isConfirmed(slotRecord, sources, minInterval)` returns `true` only when every
  source in `sources` was seen complete at least twice at the current fingerprint, with at
  least `minInterval` seconds between first and last observation.

The fingerprint is djb2 bounded to 2^32. The bound is a correctness requirement rather than
an optimisation: it makes 5.1 doubles and 5.4 integers compute identical values, so a
fingerprint computed offline still counts in game.

The test that justifies the whole module: two reads with an identical fingerprint but a
missing tooltip both times must confirm `linkComplete` and **not** confirm `tooltipComplete`.

**Verification:** 10 tests, all passing.

---

### Task 6: Policy — DONE

**Files:** `RaidInspector/Policy/Slots.lua`, `RaidInspector/Policy/Season.lua`,
`spec/Policy_spec.lua`

**Interfaces:** `Slots.ALL`, `Slots.TIER`, `Slots.isEnchantable(slot, itemSubclass)`,
`Slots.isSocketable(slot)`, `Season.CURRENT_TIER`, `Season.TIER_SET_IDS`,
`Season.MAX_EMBELLISHMENTS`.

Split into two files because they hold two kinds of judgement with different validation paths.
Slot numbers are written out literally rather than taken from the `INVSLOT_` globals, so the
file loads and tests outside the game.

Validated against the spike data afterwards: neck, waist, wrist, trinkets, back and off-hand
showed zero enchants across 83 observations, confirming the Midnight change. Shoulders showed
4 of 8 enchanted, confirming they belong on the list. Gloves showed 2 of 11 with an enchant ID
— almost certainly engineering tinkers — which is why the enchantable list is curated and
never derived from observation.

**Verification:** 9 tests, all passing.

---

### Task 7: Rules — enchants and gems — DONE

**Files:** `RaidInspector/Rules.lua`, `spec/Rules_spec.lua`,
`RaidInspector/Data/Enchants.lua`, `RaidInspector/Data/Gems.lua`

**Interfaces:** `ns.Rules.evaluateSlot(slot, parsed, slotRecord, context)` returns a dense
array of findings shaped
`{ slot, kind, severity = "error"|"warn", state = "bad"|"unknown", detail }`.

The `stateFor` helper is where the trust model from section 6 of the spec becomes code: a
negative finding is `bad` only when the evidence it needs is confirmed, and `unknown`
otherwise.

The data tables are stubs, generated properly in part 3.

**Verification:** 12 Rules tests, all passing.

---

### Task 8: Rules — tier and embellishments — DONE

**Files:** `RaidInspector/Rules.lua`, `spec/Rules_spec.lua`,
`RaidInspector/Data/Embellishments.lua`

**Interfaces:** `ns.Rules.evaluatePlayer(slots, context)` where `slots` maps slot ID to
`{ parsed, record, setID }`. Returns findings for the player as a whole, including
`tier_incomplete` and `embellishments_missing` which span multiple slots.

These are the first checks that cannot be judged per slot: you can only say someone wears 3 of
5 tier pieces once all five slots are in.

**A defect this plan originally contained**, found by running the plan's own code before
handing it over: task 8 created `Data/Embellishments.lua` but never added it to the module
list in `spec/Rules_spec.lua`. Only the test with a non-empty bonus list failed, and it failed
with an opaque nil-index error rather than a clear assertion — the other embellishment tests
passed vacuously because an empty bonus list never reaches the index. The plan was corrected
before execution.

**Verification:** 58 tests in total, all passing.

---

## Final state

```
LinkParser  16   item link -> itemID, enchant, gems, bonus IDs, modifiers
Evidence    10   fingerprint plus per-source confirmation
Policy       9   enchantable / socketable / tier slots, seasonal judgement
Rules       19   enchants, gems, empty slot, tier, embellishments
harness      4   Lua 5.1 fidelity and the deep-equal reporter
```

Merged to `master`. Continues in
`docs/superpowers/plans/2026-08-03-raid-inspector-part2-rules.md`.
