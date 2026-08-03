# Spike results

**Run:** 2026-08-03, WoW retail **12.0.7**, build **68887**
**Captures:** 22
**Slots recorded:** 184

---

## Open questions from section 14 of the spec, answered

### 14.2 — The global string for the upgrade track

`ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` exists and holds:

```
Upgrade Level: %s %d/%d
```

The line appears verbatim in the tooltip of inspected items, for example
`"Upgrade Level: Myth 6/6"` and `"Upgrade Level: Hero 3/6"`. Seven distinct variants were
observed: Myth 1/6, 2/6, 3/6, 5/6, 6/6 and Hero 3/6, 6/6.

**106 of 184 recorded slots carried such a line; 78 did not.** Items without a track — some
trinkets, crafted gear — simply have no line, so its absence is **not** evidence of "fully
upgraded". That case has to stay `unknown`.

The tooltip-first strategy from section 8 is confirmed workable.

### 14.1 — Off-hand enchantability

Three off-hands recorded, none enchanted, one of them explicitly *Held In Off-hand*
(Vexamus' Expulsion Rod). That supports the assumption that an off-hand which is not a
weapon carries no enchant.

**Still unconfirmed:** the shield case. No shield appeared in the sample.

### 14.3 — Spellthread on legs

Confirmed: legs carry an ordinary `enchantID` in the link. Nine of ten observed leg pieces
had one.

---

## Socket count: which API?

**184 comparisons, 0 mismatches.** `C_Item.GetItemStats` (the sum of the `EMPTY_SOCKET_*`
keys) and `C_Item.GetItemNumSockets` returned the same number on every single item.
`GetItemNumAddedSockets` also exists and returned 0 throughout this sample.

Conclusion: the choice does not matter. `GetItemStats` stays the primary source as the spec
says; `GetItemNumSockets` is an equivalent alternative should that ever prove more
convenient.

Note that the `EMPTY_SOCKET_*` keys mean "there is a socket here", not "this socket is
empty" — the measurements confirm it. A bracer with a filled Prismatic Socket returned
`fromGetItemStats = 1` while a gem was in it. The only socket line observed in tooltips is
`Prismatic Socket`.

---

## Parser validated against real data

**184 of 184 links parsed without a single failure.** Three things came out of the real data
that could not have been derived from documentation or reasoning:

1. **The colour prefix is `|cnIQ4:`**, no longer the classic `|cffa335ee`. The parser matches
   on `|Hitem:` and is immune to this, but an implementation that had matched on the colour
   segment would have broken here.
2. **Modifier values can be negative.** `-2147480301` occurred 22 times.
3. **A non-numeric field can follow the modifiers**: the crafter GUID, for example
   `Player-1403-0B343557`.

Maxima in the sample: 9 bonus IDs, 10 modifier pairs.

`hasDynamicData` was **never** present — 0 out of 184. Tooltip completeness cannot be
determined from that flag; it has to be inferred from the lines themselves.

---

## Enchants per slot: the policy validated

| Slot | Seen | Enchanted |
|---|---|---|
| feet | 5 | **5** |
| head | 11 | 10 |
| chest | 11 | 9 |
| legs | 10 | 9 |
| mainhand | 9 | 7 |
| finger 1 | 18 | 13 |
| finger 2 | 18 | 13 |
| shoulders | 8 | 4 |
| hands | 11 | 2 |
| neck | 16 | 0 |
| waist | 8 | 0 |
| wrist | 13 | 0 |
| trinkets | 32 | 0 |
| back | 11 | 0 |
| off-hand | 3 | 0 |

Neck, waist, wrist, trinkets, back and off-hand: **zero enchants across 83 observations.**
That confirms the Midnight change which removed cloak and bracers from the enchantable list.

The missing enchants on head, chest, legs, rings and mainhand are genuine findings — exactly
what the addon is supposed to report.

### Shoulders: confirmed enchantable

An earlier, smaller sample showed shoulders 0 out of 2, which briefly suggested the policy
was wrong. The larger sample shows **4 of 8 enchanted**, and published Midnight season 1
sources list six shoulder enchants (Akil'zon's Swiftness, Amirdrassil's Grace, Flight Of The
Eagle, Nature's Grace, Silvermoon's Mending, Thalassian Recovery). The policy is correct.

### Hands: an enchant ID that is not a required enchant

Gloves are **not** on the enchantable list, yet 2 of 11 carried an `enchantID`. Almost
certainly engineering tinkers, which occupy the same field. The rules are unaffected because
`checkEnchant` returns early for non-enchantable slots — but this is precisely the trap you
would fall into by reasoning "an enchant ID is present, therefore the slot is enchantable".
Do not derive the enchantable list from observed data.

---

## Most important finding: inspects are far less complete than assumed

Slots returned per capture, across 22 captures:

```
15, 15, 15, 15, 12, 12, 11, 11, 11, 10, 10, 7, 7, 6, 6, 4, 4, 3, 3, 3, 2, 2
```

A fully geared raider has 15 or 16 filled slots. Only **four of twenty-two** captures
returned that; the median is about 8. `GetInventoryItemLink` simply returned `nil` for the
remaining slots.

This is more severe than section 3 of the spec assumed. There it says the *payload* of a
link may be missing; in reality **entire slots** are missing. An implementation that reads a
missing slot as "empty gear slot" produces a wall of false errors on the first inspect.

The current trust model already handles this: `missing_item` requires confirmed
`itemLoaded` evidence, and that evidence never materialises for a slot that never came back.
The state stays `unknown` rather than `bad`. But there are consequences for the runtime:

1. **The scanner must record how many slots each pass returned.** A pass with 2 slots is
   barely evidence; a pass with 15 is.
2. **Rules must distinguish "slot absent from this pass" from "player wears nothing here".**
   Right now every absent slot produces an `unknown` finding, which is correct but noisy:
   fourteen grey cells per player on the first pass.
3. **The arithmetic in section 7 was too optimistic.** Two passes of 60 seconds do not
   produce a confirmed player when each pass returns only part of the slots. Expect more
   passes, and a correspondingly longer build-up phase in the UI.
