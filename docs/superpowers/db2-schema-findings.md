# DB2 schema findings

**Run:** 2026-08-03, against wago.tools for build **12.0.7.68887**
**Purpose:** establish how to derive enchant and gem quality tiers from DB2 data, before
writing the generator. Part 3 was deliberately deferred until this was measured rather than
assumed.

---

## Access

`https://wago.tools/db2/<Table>/csv?build=12.0.7.68887` returns plain CSV and accepts a
pinned build number. Sizes for the tables that matter:

| Table | Size | Rows |
|---|---|---|
| `SpellItemEnchantment` | 0.5 MB | 5336 |
| `Item` | 8.6 MB | — |
| `ItemSparse` | 48.5 MB | — |

`Item` and `SpellItemEnchantment` carry everything needed. `ItemSparse` is only useful for
display names, and at 48 MB it is not worth streaming for that alone.

---

## Enchant quality: an atlas marker inside the name

The quality tier is embedded in `SpellItemEnchantment.Name_lang` as a texture atlas marker:

```
Enchant Helm - Hex of Leeching |A:Professions-ChatIcon-Quality-12-Tier1:20:20|a   <- Silver
Enchant Helm - Hex of Leeching |A:Professions-ChatIcon-Quality-12-Tier2:20:20|a   <- Gold
```

Consecutive IDs are Tier1/Tier2 pairs of the same named enchant.

Three marker shapes exist across the table:

| Shape | Count | Meaning |
|---|---|---|
| `Quality-12-Tier1` / `Tier2` | 62 + 62 | Midnight, two tiers |
| `Quality-Tier1` / `Tier2` / `Tier3` | 123 + 120 + 119 | Older, three-tier system |
| no marker at all | 4850 | Legacy, no crafting quality |

**The ID ranges overlap and cannot be used to separate them.** Midnight enchants run
7905–8615; the older marked ones run 6379–7949. Anything keying off an ID range would
misclassify the 7905–7949 band. The marker shape is the only reliable discriminator.

The `12` in `Quality-12-` is the expansion number, which is exactly the season tag the spec
needs. Older entries carry no expansion in their marker, so they are all tagged `legacy` —
enough for the rule that matters, since `Policy.Season.CURRENT_TIER` decides what counts as
current and everything else becomes an `outdated_enchant` warning rather than `unknown`.

### Enchants without a marker are not all irrelevant

Enchant `2841` (`+$k1 Stamina`, ilvlMin 10, ilvlMax 320) was observed twice in the raid data,
on gloves. Gloves are not enchantable in Midnight, so this is almost certainly an engineering
tinker occupying the enchant field. It has no quality marker and must classify as `legacy`,
not as unknown.

### Not every enchant name follows "Enchant <Slot> - "

Spellthreads and leg armor kits are `SpellItemEnchantment` rows too, and their names look
like `+$k1 Intellect & +$k2 Stamina` or `+$k2 Agility/Strength & +$k1 Stamina`. The slot
therefore cannot be parsed from the name. That is fine: `Rules` never asks the enchant data
which slot an enchant belongs to — that comes from `Policy/Slots.lua`. The generated table
only needs `quality` and `tier`.

---

## Gem quality: a first-class column

`Item.CraftingQualityID` gives the answer directly, no inference required.

| CraftingQualityID | Gems | Meaning |
|---|---|---|
| 14 | 36 | Midnight Gold |
| 13 | 36 | Midnight Silver |
| 3 / 2 / 1 | 67 each | Older three-tier system |
| 0 | 2928 | Legacy, no crafting quality |

Gems are identified by `Item.ClassID = 3`. There are 3201 gem items in total.

The 13/14 split mirrors the enchant `Quality-12-Tier1/Tier2` split exactly — same generation,
same two-tier design.

### What was almost inferred wrongly

Before finding `CraftingQualityID`, the pattern in `ItemSparse` looked like this:

```
240889  ilvl=278  "Flawless Deadly Peridot"
240890  ilvl=295  "Flawless Deadly Peridot"
240897  ilvl=278  "Flawless Deadly Amethyst"
240898  ilvl=295  "Flawless Deadly Amethyst"
```

Consecutive IDs, identical names, item level 278 versus 295. Ranking by item level within a
name group would have produced the right answer here — but it is inference, it would need the
48 MB `ItemSparse` download, and it would break on any gem family whose tiers happen to share
an item level. `CraftingQualityID` is the actual field and costs nothing.

`ExpansionID` on these gems reads **11**, not 12, so it is not a usable season indicator.

---

## What the generator needs

| Output | Source | Derivation |
|---|---|---|
| `Data/Enchants.lua` | `SpellItemEnchantment` | `Name_lang` marker: `Quality-12-TierN` → midnight-s1 + silver/gold; `Quality-TierN` → legacy; no marker → legacy |
| `Data/Gems.lua` | `Item` where `ClassID = 3` | `CraftingQualityID`: 14 → gold, 13 → silver, both midnight-s1; 1/2/3 and 0 → legacy |
| `Data/Version.lua` | the pinned build | patch version and build number |

`ItemSparse` is not required. Neither is `ItemBonus`, until the upgrade-track fallback table
is built — and that fallback is optional, because the tooltip is the primary source and
survives a season rollover unmaintained.

Embellishments still need a source; `Data/Embellishments.lua` stays a stub for now. The spike
showed the tooltip carries `Unique-Equipped: Embellished (2)` verbatim, which may turn out to
be a simpler detection path than bonus IDs.

---

## Consequence for the tests

`Rules` tests currently load the real `Data/*.lua` modules and assert against stub IDs such
as 7364. Once those files hold 5336 generated entries, those assertions break and, worse,
the rules would be tested against production data instead of against the cases they mean to
cover. The rules tests must inject their own small data tables after loading the modules.
Shape conformance of the generated tables gets its own separate test.
