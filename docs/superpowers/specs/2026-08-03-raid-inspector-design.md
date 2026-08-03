# Raid Inspector — Design

**Datum:** 2026-08-03
**Status:** Goedgekeurd na review door Fable en Codex; klaar voor implementatieplan
**Doelversie:** World of Warcraft retail, Midnight (12.0), seizoen 1

---

## 1. Doel en scope

Een private WoW-addon waarmee een raidleider tijdens de raid in één scherm de gear-status
van alle raidleden ziet: item level, ontbrekende of zwakke enchants, lege sockets, upgrade
tracks, tier-stukken en embellishments. Vergelijkbaar met wat de WoW Audit-website toont,
maar volledig in-game.

Deze spec beschrijft de **live in-raid weergave**. Een uitgebreidere audit- of exportmodus
is een mogelijke vervolgstap en valt buiten deze spec.

### Checks in versie 1

1. Item level — gemiddeld en per slot; lege gear-slots
2. Ontbrekende enchants op enchantbare slots
3. Enchant- en gemkwaliteit (Silver versus Gold)
4. Lege sockets, en slots die een socket kúnnen krijgen maar er geen hebben
5. Upgrade track per item (Myth/Hero/Champion/Veteran + rank) en openstaande upgrades
6. Tier-stukken gedragen (x/5) en embellishments gebruikt (max 2)

---

## 2. Vastgelegde beslissingen

| Beslissing | Keuze | Reden |
|---|---|---|
| Databron | Uitsluitend in-game inspect | Moet werken op spelers zonder de addon, inclusief pugs |
| ID-tabellen | Gegenereerd uit wago.tools DB2-exports | Handmatig bijhouden is per patch foutgevoelig handwerk |
| Hoofdscherm | Raster speler × slot, plus samenvattingskolom | Maximale dichtheid; de samenvattingskolom maakt het actiegericht |
| Scanstrategie | Opportunistische achtergrondqueue met persistente cache, plus handmatige "Scan nu" | Enige aanpak die de afstandslimiet echt oplost |
| Socket-beleid | Ontbrekende toevoegbare socket is een waarschuwing | Telt als gemiste optimalisatie, zoals WoW Audit het doet |

De keuze voor inspect-only heeft twee permanente kosten die geaccepteerd zijn:
**geen dekking van spelers buiten range**, en **geen versheidssignaal** — er is geen event
dat meldt dat een ander raidlid net iets veranderd heeft. Het `source`-veld in het datamodel
houdt de deur open voor een optioneel addon-comm-kanaal later, zonder modelwijziging.

---

## 3. Geverifieerde platformbeperkingen

Deze bepalen het hele ontwerp.

- **Inspect vereist `CanInspect(unit)` en interact-afstand (~28 yd).** Spelers verder weg
  zijn niet te scannen.
- **`CanInspect` bewijst géén afstand.** Het betekent "deze soort unit mag geïnspecteerd
  worden", niet "dit verzoek gaat lukken".
- **`UnitInRange` is géén inspect-range.** Die geeft 40 yd terug (25 yd voor Evokers) en
  alleen voor groepsleden. Het is een grove voorfilter die structureel spelers doorlaat die
  op 28–40 yd staan en dus niet te inspecten zijn. Zie §7 voor hoe de queue dat opvangt.
- **De server throttelt rond 6 requests per 10 seconden.** Boven dat budget worden requests
  *stil gedropt* — er vuurt geen `INSPECT_READY`. Een timeout met backoff is dus nodig,
  niet alleen een timer. Het budget wordt gedeeld met andere addons en met handmatige
  inspects van de gebruiker. Dit getal is door de community gemeten, niet gedocumenteerd;
  de addon behandelt het als aanname met marge.
- **Er is één globale inspect-slot en de addon is niet de eigenaar.** `NotifyInspect`
  annuleert lopende inspects van Blizzards eigen `InspectFrame` en van andere addons, en
  `INSPECT_READY` vuurt ook voor requests die de addon niet gedaan heeft.
- **`UnitTokenFromGUID` is expliciet instabiel.** De token moet op eventmoment opgehaald
  worden én direct geverifieerd met `UnitGUID(unit) == guid`.
- **`CheckInteractDistance` is sinds 10.2.0 geblokkeerd in combat** voor insecure code.
  Niet gebruiken.
- **Itemdata is asynchroon.** `C_Item.GetItemInfo`, `C_Item.GetDetailedItemLevelInfo`,
  `C_Item.GetItemStats` en tooltipqueries geven `nil` of leeg terug voor items die niet in
  de lokale client-cache staan — normaal op een verse client en op patchdag.
- **Tooltipdata kan dynamisch en incompleet zijn.** "Item geladen" betekent níet "alle
  tooltipregels aanwezig". `TooltipData` draagt `hasDynamicData`; een incompleet resultaat
  moet een eigen pad krijgen en mag nooit als "regel niet aanwezig dus geen upgrade track"
  gelezen worden.
- **Gem- en socketdata kan later binnenkomen dan de itemlinks.** Eén pass per speler is
  niet altijd genoeg.
- **Socketcount zit niet in de itemlink.** De link bevat alleen de aanwezige gems.
- **`C_Item.GetItemInfo` is de genamespacete vorm**; de 16e returnwaarde is nog steeds
  `setID`. 12.0 heeft een 18e returnwaarde `itemDescription` toegevoegd.
- **Er is geen first-party API voor de upgrade track van een geïnspecteerd item.**
  `C_ItemUpgrade.GetItemUpgradeInfo` werkt alleen in de vendorcontext voor eigen items.
- **12.0 heeft het addon-restrictieframework aangescherpt** (Secret values,
  `C_RestrictedActions`). Inspect-API's staan er nu niet op, maar Blizzard schroeft
  addon-gedrag in combat actief verder dicht.

### Midnight-specifieke feiten

- Enchants hebben **twee kwaliteitstiers: Silver en Gold**. Bronze bestaat niet meer.
  Het War Within-model met rank 1/2/3 is niet van toepassing.
- **Gems zijn eveneens tweetraps** (Silver/Gold); ook ruwe gems dragen nu kwaliteit.
- **Enchantbare slots zijn veranderd**: cloak en bracers zijn eruit, helm en shoulders zijn
  terug. Actueel: helm, shoulders, chest, legs (spellthread via Tailoring), boots, beide
  ringen, wapens.
- Tier-slots zijn ongewijzigd: helm, shoulders, chest, handen, benen.
- Embellishments: maximaal 2, alleen op crafted gear; crafted gear is niet te catalyseren.

---

## 4. Architectuur

Eén afhankelijkheidsrichting. `Cache` en `Data` zijn bladeren.

```
Scanner ──▶ LinkParser ──▶ Hydrator ──▶ Rules ──▶ UI
 (async)      (puur)        (async)     (puur)
    │                          │           │
    ├──────▶ Cache             │           └──▶ Policy
    │          ▲ (alleen lezen)│
    │          └───────────────┘           └──▶ Data
    └──▶ UpgradeTrackAdapter (onder Hydrator)
```

`Hydrator` **leest** uit `Cache` maar schrijft er nooit naar: alleen rauwe data wordt
gepersisteerd (§11), afgeleide waarden nooit.

```
RaidInspector/
  RaidInspector.toc
  Core.lua                 -- namespace, eventdispatch, slash commands, combat-gating
  Roster.lua               -- groepsroster: GUID, naam, realm, klasse, spec
  Scanner.lua              -- inspect-queue: budget, tiers, timeouts, contentie
  LinkParser.lua           -- itemlink -> rauwe tabel                    [PUUR]
  Hydrator.lua             -- wacht op itemcache; ilvl, sockets, setID
  UpgradeTrackAdapter.lua  -- tooltipregel -> track/rank; locale- en buildgevoelig
  Evidence.lua             -- welk bewijs compleet was per uitlezing     [PUUR]
  Rules.lua                -- gear + bewijs + beleid -> bevindingen      [PUUR]
  Cache.lua                -- SavedVariables, schemaversie, TTL, opruiming
  UI/Grid.lua              -- raster + samenvattingskolom + dekkingsbalk
  UI/Detail.lua            -- detailpaneel per speler
  Policy/
    Slots.lua              -- enchantbare en socket-bare slots dit seizoen
    Season.lua             -- welke enchant-/gemtier actueel is, actuele tier-setIDs
  Data/                    -- GEGENEREERD, niet met de hand aanpassen
    Enchants.lua           --   enchantID -> { slot, quality, tier }   VOLLEDIG HISTORISCH
    Gems.lua               --   gemID -> { quality, tier }             VOLLEDIG HISTORISCH
    UpgradeTracks.lua      --   bonusID -> { track, rank, max }
    Embellishments.lua     --   bonusID -> { name }
    Version.lua            --   patchversie + buildnummer van generatie
  tools/generate.mjs       -- wago.tools CSV -> Data/*.lua
  tools/csv/               -- ingecheckte CSV-snapshots, voor reproduceerbare generatie
  spec/                    -- busted tests
    LinkParser_spec.lua
    Rules_spec.lua
    Evidence_spec.lua
    fixtures/
```

### Rolverdeling

**`LinkParser`** — puur. Itemlink-string in; `itemID`, `enchantID`, `gemIDs`, `bonusIDs` en
modifier-paren uit. Raakt geen enkele WoW-API aan, heeft geen state, volledig testbaar
buiten de game.

**`Hydrator`** — de asynchrone brug. Wacht met `Item:CreateFromItemLink():ContinueOnItemLoad()`
tot het item geladen is en vult dan aan: item level, socketcount, `setID` uit
`C_Item.GetItemInfo`. Levert altijd óók een `Evidence`-record: welke bronnen compleet waren.

**`UpgradeTrackAdapter`** — apart van `Hydrator` omdat tooltipparsing locale- en
buildgevoelig is en zijn eigen faalpad heeft. Levert `{ track, rank, max }` of expliciet
`unknown`, nooit een gok.

**`Evidence`** — puur. Legt per uitlezing vast welke bronnen compleet waren. Zonder deze
laag verandert `Rules` stil ontbrekende data in slechte gear; dat is de kern van §6.

**`Rules`** — puur. Neemt een gehydrateerd record, het bijbehorende bewijs, `Policy` en
`Data`; geeft een platte lijst bevindingen terug. Weet niets van events of frames. De UI
rendert uitsluitend bevindingen en raakt nooit een bonus-ID aan.

**`Policy`** — met de hand onderhouden, bewust géén gegenereerd bestand, en gesplitst omdat
het twee soorten oordeel zijn met verschillende validatiepaden. `Slots.lua`: welke slots dit
seizoen enchantbaar en socket-baar zijn. `Season.lua`: welke enchant- en gemtier als actueel
telt, en welke setID's de huidige tier vormen. `Data` blijft puur mechanisch — ID naar feit,
geen seizoensoordeel.

---

## 5. Datamodel

Alleen rauwe data wordt gepersisteerd. Alles wat afgeleid is, wordt bij het laden opnieuw
berekend — anders blijft een conclusie van vóór een data-update stil naast de nieuwe
tabellen bestaan.

```lua
PlayerRecord = {
  guid, name, realm, class, specID,
  source     = "inspect",   -- ruimte voor "comm" zonder modelwijziging
  status,                   -- zie toestandsmachine in §6
  firstSeen, lastSeen, scannedAt,
  passCount, failCount,
  slots = { [INVSLOT_HEAD] = SlotRecord, ... },
}

SlotRecord = {
  itemLink,        -- rauw; de bron van waarheid
  fingerprint,     -- hash van de link
  reads = {        -- per bewijssoort: hoe vaak compleet gezien bij deze fingerprint
    link      = { count, lastAt },
    sockets   = { count, lastAt },
    tooltip   = { count, lastAt },
    itemData  = { count, lastAt },
  },
}

SlotEvidence = {   -- per uitlezing, niet gepersisteerd
  linkComplete,    -- link droeg enchant-/gem-payload
  socketsKnown,    -- socketcount opgehaald, niet nil
  tooltipComplete, -- tooltip geleverd zonder hasDynamicData-voorbehoud
  itemLoaded,      -- ContinueOnItemLoad geslaagd
}

Finding = { slot, kind, severity, state, detail }
```

`kind` ∈ `missing_item`, `missing_enchant`, `low_enchant`, `outdated_enchant`,
`empty_socket`, `missing_socket`, `low_gem`, `outdated_gem`, `upgrades_left`,
`tier_incomplete`, `embellishments_missing`.

`severity` ∈ `error`, `warn`. `state` ∈ `ok`, `bad`, `unknown`, `stale`.

De zestien gecontroleerde slots: helm, nek, shoulders, cloak, chest, bracers, handen, riem,
benen, boots, ring 1, ring 2, trinket 1, trinket 2, main hand, off hand. Shirt, tabard en
profession tools vallen af — die laatste horen niet bij de inspecteerbare paperdoll en
hebben geen invloed op raidprestatie.

---

## 6. Vertrouwensmodel

Dit is de belangrijkste regel in de hele addon. Als het raster ooit rood kleurt op basis van
data die simpelweg nog niet binnen was, spreekt de raidleider iemand ten onrechte aan en is
de addon één keer nodig om weggegooid te worden.

### De regel

- Een **positieve** bevinding ("er zit een Gold-enchant op") mag onmiddellijk getoond
  worden. Die kan niet uit ontbrekende data ontstaan.
- Een **negatieve** bevinding wordt pas `bad` als **alle vier** onderstaande gelden:
  1. dezelfde `fingerprint` bij minstens twee uitlezingen;
  2. de bewijssoorten die díe bevinding nodig heeft waren bij minstens twee van die
     uitlezingen compleet;
  3. die twee uitlezingen liggen minstens **10 seconden** uit elkaar;
  4. de gegenereerde data is geldig voor de draaiende patchversie (§10).
- Een niet-herkend bonus-ID-patroon is `unknown`, **nooit** "geen track" of
  "volledig geüpgraded".
- Data ouder dan de TTL wordt `stale` en visueel gedimd — nooit identiek gerenderd aan een
  verse scan.

Voorwaarde 2 is wat de fingerprint alleen niet dekt: de link kan twee keer identiek én
compleet zijn terwijl de tooltipregel beide keren ontbrak of de socketcount beide keren
`nil` gaf. Dan zou de fingerprint-teller twee bevestigingen melden voor een bevinding die
nooit bewijs had. Voorwaarde 3 vangt het geval van twee snel opeenvolgende, identiek
incomplete uitlezingen.

### Bewijs per bevinding

| `kind` | vereist bewijs |
|---|---|
| `missing_item` | `itemLoaded` voor de overige slots (bewijst dat de pass echt data droeg) |
| `missing_enchant` | `linkComplete` |
| `low_enchant` / `outdated_enchant` | `linkComplete` + enchantID bekend in `Data/Enchants` |
| `empty_socket` | `linkComplete` + `socketsKnown` |
| `missing_socket` | `socketsKnown` |
| `low_gem` / `outdated_gem` | `linkComplete` + gemID bekend in `Data/Gems` |
| `upgrades_left` | `tooltipComplete`, óf bonusID herkend in `Data/UpgradeTracks` |
| `tier_incomplete` | `itemLoaded` voor alle vijf tier-slots |
| `embellishments_missing` | `linkComplete` voor alle crafted items |

`Scanner` telt de bewijssoorten op harvestmoment op, direct na het parsen en hydrateren.
Verandert de fingerprint, dan gaan alle tellers voor dat slot op nul.

### Bekend-maar-verouderd is geen onbekend

Een raider met een War Within-enchant moet **geel** zijn, niet grijs. Daarom bevatten
`Data/Enchants.lua` en `Data/Gems.lua` de **volledige historische** tabellen met een
tier-tag; `Policy/Season.lua` bepaalt welke tier als actueel geldt. Zo levert een bekende
maar verouderde ID een `outdated_enchant`-waarschuwing op, en blijft `unknown` gereserveerd
voor wat werkelijk niet herkend wordt. De DB2-exports bevatten alles al; de extra omvang is
verwaarloosbaar.

### Toestandsmachine per speler

```
unseen ──▶ queued ──▶ inflight ──┬─▶ hydrating ──▶ partial ──▶ confirmed ──▶ stale
   ▲          ▲                  │       │            │            │           │
   │          │                  │       └──▶ unknown │            │           │
   │          │       timeout (backoff, retry)        │            │           │
   │          └──────────────────┴─────────────────────            │           │
   │                                                    herbevestiging         │
   │                                                                           │
   └───◀─── unreachable ◀─── 5 opeenvolgende timeouts                          │
              │                                                                │
              └──▶ terug naar queued bij UNIT_IN_RANGE_UPDATE of na 60s re-probe
```

"Klaar" bestaat niet. Een speler blijft in rotatie tot elk slot bevestigd is, en gaat daarna
naar een trage herbevestigingscadans. **`unreachable` is nooit definitief**: de speler keert
terug in de wachtrij zodra `UNIT_IN_RANGE_UPDATE` vuurt, en anders via een trage re-probe
elke 60 seconden. Zonder die uitgang blijft de healer die bij het laden even water aan het
halen was de hele avond grijs.

---

## 7. Scanner

### Budget en wachtrijen

Maximaal 6 requests per 10 seconden; de addon houdt **5 per 10 s** aan omdat het budget
gedeeld wordt met andere addons en met handmatige inspects.

Omdat `UnitInRange` tot 40 yd doorlaat terwijl inspect op ~28 yd stopt, zou één naïeve
wachtrij structureel budget verbranden aan spelers die niet te bereiken zijn. Daarom drie
wachtrijen met een vast budgetaandeel:

| Rij | Inhoud | Aandeel |
|---|---|---|
| A — warm | `CanInspect` waar, `UnitInRange` waar, geen recente timeout | ≥ 70% |
| B — herbevestiging | `confirmed`, cadans verlopen | ~20% |
| C — koud | recente timeout of `unreachable` | ≤ 10% |

Rij C mag nooit meer dan zijn aandeel opeten. Zonder die grens kunnen enkele spelers op
30–40 yd afstand — die `UnitInRange` wél passeren maar inspect niet — alle bruikbare scans
van dichtbijstaande raidleden verhongeren.

| Waarde | Standaard |
|---|---|
| Requestbudget | 5 per 10 s |
| Timeout per request | 3 s |
| Backoff | basis 5 s, ×2 per opeenvolgende timeout, plafond 60 s (5/10/20/40/60) |
| Retry-cap per speler per pass | 3 |
| `unreachable` na | 5 opeenvolgende timeouts |
| Re-probe van `unreachable` | elke 60 s, plus direct bij `UNIT_IN_RANGE_UPDATE` |
| Herbevestigingscadans na `confirmed` | elke 10 min |
| Minimuminterval tussen bevestigende uitlezingen | 10 s |

**Doorrekening.** Bij 5 requests per 10 s is de bovengrens 0,5 inspect per seconde. Eén
ronde over 30 spelers duurt dus minimaal 60 seconden, en de twee passes die het
vertrouwensmodel eist minimaal **twee minuten** — en dat is de ideale situatie zonder
combatpauzes, zonder concurrerende addons en zonder timeouts. De herbevestigingscadans is
daarna goedkoop: 30 requests per 10 minuten is 10% van het budget. De UI moet die eerste
twee minuten expliciet als opbouwfase tonen (§9), anders lijkt de addon stuk.

### Handmatige scan

`/ri scan` en de knop in de UI doen één prioriteitsronde: wachtrij leegmaken, alle backoffs
resetten, iedereen die op dat moment `CanInspect` en `UnitInRange` passeert in rij A zetten,
en na afloop de dekking rapporteren. Bedoeld voor het moment vlak voor de pull, wanneer de
raid gestackt staat en de dekking maximaal is.

### Contentie

- Elke `INSPECT_READY` wordt op GUID gematcht tegen de eigen openstaande request.
- Events van andere addons worden **wel** uitgelezen — dat is gratis dekking.
- `ClearInspectPlayer()` wordt **alleen** aangeroepen na een inspect die de addon zelf
  gestart heeft, en alleen als Blizzards `InspectFrame` dicht is. Na het meelezen van een
  vreemd event nooit: de aanvrager heeft die data zelf nog nodig.
- De queue pauzeert zolang `InspectFrame` zichtbaar is.

### Uitlezen

`GetInventoryItemLink(unit, slot)` is alleen geldig tot de volgende `NotifyInspect` of
`ClearInspectPlayer`. Alle zestien slots worden dus binnen de `INSPECT_READY`-handler
uitgelezen. De unit-token wordt op dat moment opgehaald met `UnitTokenFromGUID` en direct
geverifieerd met `UnitGUID(unit) == guid` — raid-indices verschuiven tussen request en
antwoord, en de API is expliciet als instabiel gedocumenteerd.

`GetInspectSpecialization(unit)` is pas geldig na `INSPECT_READY`; daar vastleggen.

`C_PaperDollInfo.GetInspectItemLevel(unit)` dient als **ruwe** kruiscontrole op het zelf
berekende gemiddelde, met tolerantie. Een exacte vergelijking is onbetrouwbaar zolang de
eigen berekening Blizzards weging voor tweehanders, off-hands en lege slots niet exact
nabootst; een groot verschil is een signaal, een klein verschil niet.

### Combat

De scanner pauzeert hard op `PLAYER_REGEN_DISABLED` en `ENCOUNTER_START`, en hervat op
`PLAYER_REGEN_ENABLED` en `ENCOUNTER_END`. Scannen tijdens een encounter levert niets op en
Blizzard schroeft addon-gedrag in combat actief verder dicht.

---

## 8. Regels en beleid

### Curatielijsten (`Policy/`, Midnight seizoen 1)

| Lijst | Slots |
|---|---|
| Enchantbaar | helm, shoulders, chest, legs (spellthread), boots, ring 1, ring 2, main hand, off-hand **wapen** |
| Socket toe te voegen | helm, bracers, riem |
| Tier | helm, shoulders, chest, handen, benen |

Schilden en held-in-off-hand items zijn niet enchantbaar; alleen een off-hand *wapen* telt
mee. De actuele tier-setIDs staan uitsluitend in `Policy/Season.lua` — niet ook in `Data/`,
want twee bronnen voor hetzelfde feit lopen gegarandeerd uiteen.

### Zwaarte

**Fout** — leeg gear-slot; ontbrekende enchant op een enchantbaar slot; leeg socket.

**Waarschuwing** — Silver in plaats van Gold enchant of gem; enchant of gem uit een vorig
seizoen; socket-baar slot zonder socket; openstaande upgrades; tier onder 5/5; minder dan
2 embellishments.

**Onbekend** — bonus-ID-patroon niet herkend; item nog niet uit de cache geladen; vereist
bewijs ontbreekt; gegenereerde data ongeldig voor deze patchversie.

### Randgevallen die anders valse meldingen geven

- Een tweehandig wapen maakt een lege off-hand **correct**. Geen bevinding.
- Crafted gear heeft **geen** upgrade track. Niet melden als "0 upgrades open".
- De track-noemer verschilt per track en per seizoen. `/6` hardcoden gaat mis.
- Lege sockets = totaal aantal sockets − gems in de link. De `EMPTY_SOCKET_*`-sleutels uit
  `C_Item.GetItemStats` betekenen "hier zit een socket", **niet** "deze socket is leeg" —
  de sleutelnaam is misleidend en mag niet letterlijk genomen worden.

### Bronnen per check

| Check | Primaire bron | Fallback / kruiscontrole |
|---|---|---|
| Item level | `C_Item.GetDetailedItemLevelInfo` | `C_PaperDollInfo.GetInspectItemLevel`, ruw |
| Enchant | `enchantID` uit de link | — |
| Enchantkwaliteit | `Data/Enchants.lua` + `Policy/Season.lua` | — |
| Socketcount | te bepalen in de spike: `C_Item.GetItemNumSockets` / `GetItemNumAddedSockets` versus `C_Item.GetItemStats` | DB2-afleiding als testoracle |
| Gems | `gemIDs` uit de link | — |
| Upgrade track | `C_TooltipInfo.GetHyperlink` via `UpgradeTrackAdapter` | `Data/UpgradeTracks.lua` |
| Tier | `setID` uit `C_Item.GetItemInfo` (16e return) | — |
| Embellishments | bonus-ID's uit de link | — |

De tooltip is bewust de **primaire** bron voor de upgrade track: die overleeft een
seizoenswissel zonder enig onderhoud, terwijl bonus-ID's per seizoen opnieuw uitgegeven
worden. Het patroon wordt opgebouwd uit `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING`
("Upgrade Level: %s %d/%d") zodat het ook op een niet-Engelse client werkt. Bij het bouwen
van het Lua-patroon: magische tekens escapen, `%s` naar een lazy capture (tracknamen bevatten
spaties), `%d` naar `(%d+)`.

---

## 9. UI

Eén scrollframe met maximaal dertig rijen. Per rij: klassegekleurde naam, gemiddeld ilvl,
zestien slotcellen, en rechts een samenvattingskolom met aantal en zwaarte van de problemen.
Standaard wordt op die kolom gesorteerd.

- Cellen zijn texturen uit één frame-pool, met één gedeelde `OnEnter`/`OnLeave` die de
  gedeelde `GameTooltip` aanstuurt. Geen `FontString` per cel.
- Alleen de rij waarvan net data binnenkwam wordt hertekend. Het raster wordt nooit in zijn
  geheel opnieuw opgebouwd per event.
- De vier celtoestanden worden onderscheiden met **vorm én kleur**. Alleen rood-groen is
  onleesbaar voor kleurenblinde gebruikers.
- Klassekleur in de naam en zwaartekleur in de cellen vechten visueel om aandacht; de cellen
  zijn het dominante kanaal en de naamkleur blijft gedempt.
- Bovenin staat permanent de dekking. Tijdens de eerste twee minuten expliciet als
  opbouwfase: *"Bezig met scannen — 12/30 bevestigd"*, daarna
  *"21/30 gescand — 9 buiten range: <namen>"*.
- Verse `unknown` mag nooit onder verouderde `bad` gesorteerd worden; de leeftijd van de
  laatste verse scan staat per rij zichtbaar.
- Klik op een rij of cel opent `UI/Detail.lua` met de volledige slot-voor-slot uitsplitsing.

---

## 10. Data-generator

`tools/generate.mjs` haalt de DB2-CSV-exports van wago.tools (ItemSparse, ItemBonus,
SpellItemEnchantment en verwanten) en schrijft `Data/*.lua`. Per patch één commando. De
gebruikte CSV-snapshots worden in `tools/csv/` ingecheckt zodat een generatie reproduceerbaar
is.

- `Data/Version.lua` bevat de **patchversie** én het buildnummer van het moment van
  generatie.
- **Degradatie gaat op patchversie, niet op buildnummer.** Buildnummers lopen bijna
  wekelijks op door hotfixes die geen enkel item raken; degraderen op build zou de addon het
  grootste deel van elk seizoen in kreupele modus zetten, precies het tegenovergestelde van
  wat de beveiliging moet doen. Regel: een nieuwere **patchversie** dan de data →
  hard degraderen naar `unknown` voor alles wat van `Data/` afhangt. Een nieuwer **build**
  binnen dezelfde patch → zachte banner "data mogelijk verouderd", verder gewoon werken.
- `Policy/` wordt **niet** gegenereerd. Welke enchants dit seizoen als actueel gelden en
  welke slots een socket kunnen krijgen is curatie, niet af te leiden uit DB2.
- `Enchants.lua` moet ook `SpellItemEnchantment`-entries meenemen die van **Tailoring en
  Leatherworking** komen, niet alleen van Enchanting — spellthreads en leg armor kits zitten
  in hetzelfde enchantID-veld van de link.
- Bestaand precedent voor de pipeline: [WowDbScripts](https://github.com/thespags/WowDbScripts).

**Onderhoudsrisico, expliciet benoemd.** Elk seizoen veranderen enchant-ID's, gem-ID's,
track-bonus-ID's, setID's, embellishment-ID's en track-noemers, en kan het CSV-schema van
wago.tools verschuiven waardoor de generator breekt. De mitigaties zijn: patchversie-gebonden
degradatie, volledige historische tabellen zodat oude gear herkend blijft, en een zo klein
mogelijk gegenereerd oppervlak — `setID` in plaats van een tier-itemtabel, en de tooltip in
plaats van de track-tabel.

---

## 11. Persistentie

- SavedVariables, gesleuteld op GUID. Omvang is geen probleem: dertig spelers × zestien
  slots aan rauwe links is hooguit enkele honderden kilobytes.
- Schemaversie in het bestand. Bij een versieverschil wordt de cache verworpen in plaats van
  gemigreerd.
- Opruimen bij login: records waarvan `lastSeen` ouder is dan **30 dagen** vervallen.
- Data ouder dan **2 uur** wordt `stale`.
- Alle afgeleide waarden worden bij het laden opnieuw berekend, nooit gepersisteerd.
  Dat betekent tot 480 links opnieuw hydrateren bij login; dat gaat **door dezelfde queue**,
  niet in één frame.
- Gepersisteerde data wordt uitsluitend als `stale` getoond, met leeftijd erbij.

---

## 12. Tests

`LinkParser`, `Evidence` en `Rules` draaien onder **busted** in gewone Lua, zonder
WoW-client. Dat zijn de modules waar de subtiele fouten zitten, en ze zijn puur juist om dit
mogelijk te maken.

- **`LinkParser`** — het testcorpus bestaat bewust vooral uit crafted, embellished,
  gesocketde en tier-links, uit de live game gehaald. Een itemlink is geen vaste
  kolomsplitsing maar een geneste structuur met lengte-geprefixte lijsten gevolgd door
  key/value-modifierparen. Naïef op index parsen werkt prima op gedropte gear en breekt
  precies op de items waar checks 3 en 6 over gaan. Het corpus wordt elk seizoen ververst.
- **`Evidence`** — expliciet getest op het scenario dat het hele model rechtvaardigt: twee
  uitlezingen met identieke fingerprint maar beide keren ontbrekende tooltip- of socketdata
  mogen géén `bad` opleveren.
- **`Rules`** — tabelgedreven: elke `kind`, elke `severity`, de vier voorwaarden uit §6, en
  het onderscheid tussen bekend-maar-verouderd (`warn`) en werkelijk onbekend (`unknown`).
- **`Scanner`** en **`UI`** blijven dun genoeg voor handmatige verificatie in-game.

---

## 13. Buiten scope

Niet haalbaar via inspect, en bewust vastgelegd zodat het er later niet insluipt:

- Great Vault-voortgang, verdiende crests, raid kills — die komen van Blizzards Armory API.
- Tijdelijke wapen-enchants en oils van anderen; `GetWeaponEnchantInfo` werkt alleen voor
  jezelf en temp enchants staan niet in de itemlink.
- Consumables.
- Profession tools.
- Een versheidssignaal: er is geen event dat meldt dat een ander raidlid geregemd heeft.

Buiten scope voor versie 1, maar bewust niet uitgesloten:

- Addon-comm-kanaal voor volledige, directe data van raidleden die de addon wél hebben.
  Het `source`-veld staat er al voor klaar.
- Audit- en exportmodus buiten de raid.

---

## 14. Nog in-game te verifiëren

De oorspronkelijke vijf punten zijn teruggebracht tot twee; de rest is uit documentatie
beantwoord en in de spec verwerkt (gems zijn tweetraps, spellthread bezet het
enchantID-veld, profession tools vallen buiten scope,
`ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` is de te gebruiken globale string).

1. **Schilden en held-in-off-hand.** Aangenomen wordt: off-hand *wapens* vereisen een
   enchant, schilden en frills niet. Het schildgeval moet bevestigd worden.
2. **Overleeft `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` 12.0 onder dezelfde naam?**
   Met `/dump` te controleren, samen met de exacte regelvorm.

---

## 15. Implementatievolgorde

Er zit één afhankelijkheidsval in dit ontwerp: `Rules` wordt geschreven tegen een aangenomen
vorm van het gehydrateerde record, terwijl juist de *invoer* van de `Hydrator` het meest
onzeker is. Gedraagt `GetItemStats` zich anders voor andermans bonus-ID-links op 12.0, of
ziet de tooltipregel er anders uit, dan moeten `Rules` en al zijn fixtures overnieuw.
Daarom deze volgorde:

1. **`LinkParser` plus fixture-corpus.** Puur, direct testbaar, geen afhankelijkheden.
2. **Een wegwerp-spike in-game** die de drie risicovolle aannames verifieert: welke
   socketcount-API werkt voor andermans items, hoe de upgrade-tooltipregel er precies
   uitziet en hoe incompleet eerste-pass inspectlinks in de praktijk zijn. Levert echte
   gehydrateerde fixtures op.
3. **`Evidence`, `Rules` en `Policy`** tegen die fixtures.
4. **`Scanner`, `Hydrator`, `UpgradeTrackAdapter`, `Cache`.**
5. **UI.**
6. **Generator**, met gestubde `Data/`-tabellen tot dat moment.
