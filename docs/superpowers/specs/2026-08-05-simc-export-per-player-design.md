# SimC export per player — Design

**Date:** 2026-08-05
**Status:** Approved, not yet implemented
**Depends on:** the SimC export built in `2026-08-03-simhammer-inspector-part6-simc.md`

---

## 1. Purpose

The export currently works on a set: every player whose role is toggled on, bundled into one
blob. That is the right default for simming a raid, and the wrong shape for the thing you
actually do most often — you have clicked one player in the grid because something about their
gear looks off, and you want *their* profile in SimulationCraft to find out how much it costs.

Today that means exporting the whole raid and hunting for their block in the text. This adds a
single-player export where the question is already asked: the detail panel.

Out of scope: any change to the profile format, and any new slash command. `/sh simc target`
and `/sh simc self` already cover the cases outside the grid.

---

## 2. Locked-in decisions

| Decision | Choice | Reason |
|---|---|---|
| Trigger | A `SimC` button in the detail panel title bar, left of the close button | Costs no vertical space, sits next to the name it acts on, and the title bar is nearly empty |
| Unavailable profile | Button greyed, reason in the tooltip | The panel already refreshes every 2 s, so the button turns itself on when the scan lands — no dead click, no window that opens to say nothing |
| Role toggles in single-player mode | Hidden | Each toggle rebuilds the full raid bundle; leaving them live means one click discards the export you just opened |
| Export window | The existing one, in a single-player mode | A second window for the same job would drift from the first |

---

## 3. One source of truth for availability

`SimcExport.profile` refuses to build a profile without talents, spec, class or name, and
returns `nil, reason`. The tooltip needs exactly that knowledge before the click happens. Two
copies of it would drift, and the failure mode is silent: a button that looks available and
does nothing.

**`SimcExport.validate(player)`** — the guard clauses from `profile`, extracted verbatim.
Returns `true`, or `nil` plus the reason string. `profile` calls it first and returns its
reason unchanged, so existing callers and their messages are untouched.

**`Core.simcAvailability(guid)`** — builds `simcPlayer(guid)` and passes it to `validate`.
When `simcPlayer` returns nil (no roster info or no record at all) the reason is
`"not scanned yet"`. Returns `ok, reason`.

Both the tooltip and the click read from `simcAvailability`. Reason strings stay in English,
matching the rest of the UI ("not scanned", "embellishments unknown").

Cost: `simcPlayer` builds a table of at most 16 slots, once per 2 s, for the one selected
player. Not worth caching.

---

## 4. Theme.button gains a disabled state

`Theme.button` has no disabled state, and its tooltip is captured in a closure at creation
time. Both are needed here, and both belong in the shared widget rather than in a hand-rolled
button in Detail — four hand-rolled buttons drift apart within a week, which is why
`Theme.button` exists.

- `b:SetTooltip(text)` — writes `b.tooltip`; `OnEnter` reads the field instead of the upvalue.
  The `tooltip` constructor argument keeps working by setting the same field.
- `b:SetEnabled(bool)` — when disabled: text in `textFaint`, no hover brightening, `OnClick`
  returns without calling the handler. The tooltip still shows on hover; that is the whole
  point of the disabled state here.

Existing callers in `Grid.lua` pass no new arguments and behave identically.

---

## 5. Wiring in the detail panel

The button is created once in `Detail.create()`, anchored `RIGHT` of the close button.

`Detail.show(guid)` stores the guid on the frame and sets the button state each pass:

- **No entry** — the early return at `Detail.lua:106` must disable the button too. Miss this
  and a button armed for the previous player stays clickable on a panel that says
  "no data for this player yet".
- **Entry present** — `Core.simcAvailability(guid)` decides enabled state and tooltip. When
  available the tooltip reads `Copy this player's SimulationCraft profile`.

The click reads the guid off the frame, not from a closure captured at creation time, when the
guid was nil.

---

## 6. Single-player export

**`Core.exportSimcPlayer(guid)`** builds the one player and goes through the same `showBundle`
path as the raid export, passing the player's name as the subject. No second export path.

**`Export.show(text, skipped, exported, subject)`** — `subject` absent gives exactly today's
behaviour. `subject` present:

- role bar hidden
- title `SimulationCraft export — <name>`
- status line `1 profile · Ctrl+C copies and closes`

The `exported == 0` branch currently explains itself in terms of roles ("no roles selected",
"no players matched those roles yet"). Neither is true in single-player mode, so with a
subject it says `could not build a profile for <name>` in the same warning colour.

Status text, skipped line and scroll frame stay anchored at fixed offsets from the window
rather than to the role bar, so hiding the role bar leaves roughly 22 px of empty space under
the title. Re-anchoring three widgets on every `show` is more moving parts than one blank line
is worth. Accepted deliberately.

`showBundle` still reports skipped players; for a single player that list can only be
non-empty if availability was true at click time and the profile failed anyway, which the
window will then say out loud rather than showing an empty box.

---

## 7. Testing

`SimcExport` is pure and runs in the busted harness:

- `validate` returns the right reason for each missing field, and `true` for a complete player
- `profile` still returns those same reasons — the extraction changed no behaviour
- a valid player still produces byte-identical profile text (existing tests cover this)

`Detail`, `Export` and `Theme` touch the WoW API and do not run in the harness. Verified in
game via `tools/deploy.ps1`:

1. Click a scanned player → button is live, click opens the window with one profile, no role
   toggles, name in the title
2. Click a player who has not answered an inspect → button greyed, tooltip gives the reason
3. Watch a player mid-scan → button turns itself on within a refresh tick of the data landing
4. `/sh simc` from the grid toolbar → role toggles back, unchanged behaviour
