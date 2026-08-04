# Simhammer Inspector — Implementation plan, part 6: SimC export

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One button that produces SimulationCraft profiles for every DPS in the raid, ready to paste into Simhammer.

**Architecture:** Profile assembly is a pure module that takes parsed item data plus player metadata and returns text. That is what makes it testable against the 184 real item links already captured, rather than discovered to be malformed in a raid.

## Feasibility, established by reading the reference implementation

The SimulationCraft addon is installed at
`Interface\AddOns\Simulationcraft`, and its `core.lua` is the authority on the
format. Everything below was read from it rather than reconstructed.

**Talents for inspected players are available.** `C_Traits.GenerateInspectImportString(unit)`
returns the talent build string for a unit you have inspected. The SimC addon itself does not
use it — it only ever exports the player — so this is the one part with no reference
implementation to copy. It must be called after `INSPECT_READY`, possibly deferred a frame.

**Item line format**, from `GetItemStringFromItemLink`:

```
<slot>=,id=<itemID>,enchant_id=<id>,gem_id=<g1>/<g2>,bonus_id=<b1>/<b2>,crafted_stats=<s1>/<s2>,crafting_quality=<q>
```

- `enchant_id` only when non-zero
- `gem_id` with trailing zeros stripped
- `crafted_stats` collected from modifier pairs of type 29 and 30
- `drop_level` from type 9, `content_tuning` from 28, `redirected_base_stats` from 64
- `gem_bonus_id` from a count-prefixed list that follows the modifier pairs, offset by 2
- `crafting_quality` from `C_TradeSkillUI.GetItemCraftedQualityByItemInfo`

**Header format**, from the profile assembly:

```
# <Name> - <Spec> - <date> - <region>/<realm>
<class>="<Name>"
level=<n>
race=<race>
region=<region>
server=<realm>
role=<role>
spec=<spec>
talents=<string>
```

Class, race, spec and realm are all tokenised: lowercased, spaces to underscores.

**SimC slot names** map onto the existing `SLOTS` order one for one:
head, neck, shoulder, back, chest, wrist, hands, waist, legs, feet, finger1, finger2,
trinket1, trinket2, main_hand, off_hand.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Output | Full SimC profiles | Live gear beats the Armory, which lags and misses characters |
| Delivery | Copy box in the addon | No file paths, works today |
| Who | DPS only | Role DAMAGER; tanks and healers are rarely simmed |
| Simhammer | Needs a new import path | Its roster import parses `Name-Realm` and fetches from the Armory; it cannot accept SimC today |

## Global constraints

Unchanged: Lua 5.1 only, no WoW globals in pure modules, no `#` on tables with holes,
English throughout.

---

### Task 1: LinkParser — gem bonus IDs

**Files:** `SimhammerInspector/LinkParser.lua`, `spec/LinkParser_spec.lua`

**Interfaces:** the parse result gains `gemBonusIDs`, a dense array. Empty when absent.

SimC emits `gem_bonus_id` from a count-prefixed list that sits two fields past the end of the
modifier pairs. The parser currently stops at the modifiers, so that section is unreachable.

- [ ] **Step 1:** Write failing tests using the real captured links, asserting `gemBonusIDs`
      is an empty table for items without them and reads the list where present.
- [ ] **Step 2:** Run and confirm failure.
- [ ] **Step 3:** Extend `parse` to read the count at `modCountIndex + 2 * modCount + 2` and
      the entries that follow.
- [ ] **Step 4:** Run and confirm pass.
- [ ] **Step 5:** Commit.

---

### Task 2: SimcExport — the pure profile builder

**Files:** `SimhammerInspector/SimcExport.lua`, `spec/SimcExport_spec.lua`

**Interfaces:**
- `ns.SimcExport.tokenize(text)` lowercases, replaces spaces and apostrophes with underscores.
- `ns.SimcExport.itemLine(simcSlot, parsed)` returns one item line, or `nil` when `parsed` is nil.
- `ns.SimcExport.profile(player)` returns the full profile text. `player` carries
  `name, realm, region, class, race, level, spec, role, talents, slots`.
- `ns.SimcExport.bundle(players)` joins profiles with a blank line between them.

Pure: no WoW API, no state. Tested against the real captured links.

- [ ] **Step 1:** Write failing tests covering the item line for a plain item, one with an
      enchant and gem, and the crafted item with ten modifier pairs from the fixtures;
      tokenisation of a realm with a space; a full profile; and a bundle of two.
- [ ] **Step 2:** Run and confirm failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run and confirm pass.
- [ ] **Step 5:** Commit.

---

### Task 3: Capture talents, race and level

**Files:** `SimhammerInspector/Scanner.lua`, `SimhammerInspector/Roster.lua`

`C_Traits.GenerateInspectImportString` needs the unit and only works after a successful
inspect. It is called inside the `INSPECT_READY` handler, guarded by `pcall` because it is a
new dependency and an error must not take the scanner down again.

- [ ] **Step 1:** Store `race` and `level` on the roster entry.
- [ ] **Step 2:** In `harvest`, capture the talent string and record whether the call
      succeeded, so a missing talent string is visible rather than silent.
- [ ] **Step 3:** Verify all files parse and the suite still passes.
- [ ] **Step 4:** Commit.

---

### Task 4: The export window

**Files:** `SimhammerInspector/UI/Export.lua`, `SimhammerInspector/Core.lua`, `SimhammerInspector.toc`

A scrolling multi-line edit box with the text selected, plus a line stating how many profiles
were produced and which players were skipped and why.

**A profile without talents is worse than no profile**: it sims as an unspecced character and
produces a number that looks real. Players whose talent string is missing are listed as
skipped rather than exported incomplete.

- [ ] **Step 1:** Build the window with a `ScrollFrame` and `EditBox`, Escape to close.
- [ ] **Step 2:** Wire `/sh simc` and a button in the grid title bar.
- [ ] **Step 3:** Report skipped players and the reason.
- [ ] **Step 4:** Verify, deploy, commit.

---

## Follow-up, in the Simhammer repository

Its roster import (`roster_handlers.rs` → `parse_member_list`) takes `Name-Realm` lines and
fetches from the Armory. Accepting SimC profiles needs a new path that splits a blob on
profile boundaries and stores each as `source_simc` directly, skipping the Armory round trip.
That is a separate piece of work in a separate repository and is not part of this plan.
