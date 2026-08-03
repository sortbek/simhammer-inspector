# Raid Inspector — Design

**Datum:** 2026-08-03
**Status:** Goedgekeurd, klaar voor implementatieplan
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
| Scanstrategie | Opportunistische achtergrondqueue met persistente cache | Enige aanpak die de afstandslimiet echt oplost |
| Socket-beleid | Ontbrekende toevoegbare socket is een waarschuwing | Telt als gemiste optimalisatie, zoals WoW Audit het doet |

De keuze voor inspect-only heeft twee permanente kosten die geaccepteerd zijn:
**geen dekking van spelers buiten range**, en **geen versheidssignaal** — er is geen event
dat meldt dat een ander raidlid net iets veranderd heeft. Het `source`-veld in het datamodel
houdt de deur open voor een optioneel addon-comm-kanaal later, zonder modelwijziging.

---

## 3. Geverifieerde platformbeperkingen

Deze zijn gecontroleerd tegen de huidige API-documentatie en bepalen het hele ontwerp.

- **Inspect vereist `CanInspect(unit)` en interact-afstand (~28 yd).** Spelers verder weg
  zijn niet te scannen.
- **De server throttelt rond 6 requests per 10 seconden.** Boven dat budget worden requests
  *stil gedropt* — er vuurt geen `INSPECT_READY`. Een timeout met backoff is dus nodig,
  niet alleen een timer. Het budget wordt gedeeld met andere addons en met handmatige
  inspects van de gebruiker.
- **Er is één globale inspect-slot en de addon is niet de eigenaar.** `NotifyInspect`
  annuleert lopende inspects van Blizzards eigen `InspectFrame` en van andere addons, en
  `INSPECT_READY` vuurt ook voor requests die de addon niet gedaan heeft.
- **`CheckInteractDistance` is sinds 10.2.0 geblokkeerd in combat** voor insecure code.
  Niet gebruiken.
- **Itemdata is asynchroon.** `C_Item.GetItemInfo`, `GetDetailedItemLevelInfo`,
  `C_Item.GetItemStats` en tooltipqueries geven `nil` of leeg terug voor items die niet in
  de lokale client-cache staan — normaal op een verse client en op patchdag.
- **Gem- en socketdata kan later binnenkomen dan de itemlinks.** Eén pass per speler is
  niet altijd genoeg.
- **Socketcount zit niet in de itemlink.** De link bevat alleen de aanwezige gems.
- **Er is geen first-party API voor de upgrade track van een geïnspecteerd item.**
  `C_ItemUpgrade.GetItemUpgradeInfo` werkt alleen in de vendorcontext voor eigen items.
- **12.0 heeft het addon-restrictieframework aangescherpt** (Secret values,
  `C_RestrictedActions`). Inspect-API's staan er nu niet op, maar Blizzard schroeft
  addon-gedrag in combat actief verder dicht.

### Midnight-specifieke feiten

- Enchants hebben **twee kwaliteitstiers: Silver en Gold**. Bronze bestaat niet meer.
  Het War Within-model met rank 1/2/3 is niet van toepassing.
- **Enchantbare slots zijn veranderd**: cloak en bracers zijn eruit, helm en shoulders zijn
  terug. Actueel: helm, shoulders, chest, legs (spellthread via Tailoring), boots, beide
  ringen, wapens.
- Tier-slots zijn ongewijzigd: helm, shoulders, chest, handen, benen.
- Embellishments: maximaal 2, alleen op crafted gear; crafted gear is niet te catalyseren.

---

## 4. Architectuur

Vijf lagen, één afhankelijkheidsrichting. `Cache` en `Data` zijn bladeren.

```
Scanner ──▶ LinkParser ──▶ Hydrator ──▶ Rules ──▶ UI
 (async)      (puur)        (async)     (puur)
    │                          │           │
    └──────▶ Cache ◀───────────┘           └──▶ Data
```

```
RaidInspector/
  RaidInspector.toc
  Core.lua            -- namespace, eventdispatch, slash commands, combat-gating
  Roster.lua          -- groepsroster: GUID, naam, realm, klasse, spec
  Scanner.lua         -- inspect-queue: budget, timeouts, retries, contentie
  LinkParser.lua      -- itemlink -> rauwe tabel                    [PUUR]
  Hydrator.lua        -- wacht op itemcache; ilvl, sockets, setID, upgrade track
  Rules.lua           -- gear + beleid -> bevindingen               [PUUR]
  Cache.lua           -- SavedVariables, schemaversie, TTL, opruiming
  UI/Grid.lua         -- raster + samenvattingskolom + dekkingsbalk
  UI/Detail.lua       -- detailpaneel per speler
  Data/                -- GEGENEREERD, niet met de hand aanpassen
    Enchants.lua      --   enchantID -> { slot, quality }
    Gems.lua          --   gemID -> { quality }
    UpgradeTracks.lua --   bonusID -> { track, rank, max }
    Embellishments.lua--   bonusID -> { name }
    TierSets.lua      --   setID -> { season, slots }
    Build.lua         --   buildnummer waarop de data gegenereerd is
  Policy.lua          -- CURATIE, met de hand: enchantbare slots, socket-bare slots,
                      --   actuele tier-setIDs per seizoen
  tools/generate.mjs  -- wago.tools CSV -> Data/*.lua
  spec/               -- busted tests
    LinkParser_spec.lua
    Rules_spec.lua
    fixtures/links.lua
```

### Rolverdeling

**`LinkParser`** — puur. Neemt een itemlink-string, geeft `itemID`, `enchantID`, `gemIDs`,
`bonusIDs` en modifier-paren terug. Raakt geen enkele WoW-API aan en heeft geen state.
Volledig testbaar buiten de game.

**`Hydrator`** — de asynchrone brug. Neemt geparseerde links, wacht met
`Item:CreateFromItemLink():ContinueOnItemLoad()` tot het item geladen is, en vult daarna aan:
item level, socketcount uit `C_Item.GetItemStats`, `setID` uit `GetItemInfo` (16e returnwaarde),
en de upgrade track uit de tooltip. Produceert pas dan een compleet record.
Zonder deze module lekt async logica in `Scanner` of `Rules`.

**`Rules`** — puur. Neemt een gehydrateerd record plus `Policy` en `Data`, geeft een platte
lijst bevindingen terug (`slot`, `kind`, `severity`, `state`, `detail`). Weet niets van
events of frames. De UI rendert uitsluitend bevindingen en raakt nooit een bonus-ID aan.

**`Policy`** — met de hand onderhouden, bewust géén gegenereerd bestand. Welke slots dit
seizoen enchantbaar zijn, welke een socket kunnen krijgen en welke setID's de actuele tier
vormen, is curatie: DB2-data vertelt wél wat een enchant past, niet wat dit seizoen als
"actueel" telt.

---

## 5. Datamodel

Alleen rauwe data wordt gepersisteerd. Alles wat afgeleid is, wordt bij het laden opnieuw
berekend — anders blijft een conclusie van vóór een data-update stil naast de nieuwe
tabellen bestaan.

```lua
PlayerRecord = {
  guid, name, realm, class, specID,
  source     = "inspect",   -- ruimte voor "comm" zonder modelwijziging
  status,                   -- zie toestandsmachine hieronder
  firstSeen, lastSeen, scannedAt,
  passCount, failCount,
  slots = { [INVSLOT_HEAD] = SlotRecord, ... },
}

SlotRecord = {
  itemLink,        -- rauw; de bron van waarheid
  fingerprint,     -- hash van de link, voor bevestigingstelling
  confirmations,   -- hoe vaak dezelfde fingerprint in aparte passes gezien is
  readAt,
}

Finding = {
  slot, kind, severity, state, detail,
}
```

`kind` ∈ `missing_item`, `missing_enchant`, `low_enchant`, `empty_socket`,
`missing_socket`, `low_gem`, `upgrades_left`, `tier_incomplete`, `embellishments_missing`.

`severity` ∈ `error`, `warn`.
`state` ∈ `ok`, `bad`, `unknown`, `stale`.

De zestien gecontroleerde slots: helm, nek, shoulders, cloak, chest, bracers, handen, riem,
benen, boots, ring 1, ring 2, trinket 1, trinket 2, main hand, off hand. Shirt en tabard
vallen af.

---

## 6. Vertrouwensmodel

Dit is de belangrijkste regel in de hele addon. Als het raster ooit rood kleurt op basis
van data die simpelweg nog niet binnen was, spreekt de raidleider iemand ten onrechte aan
en is de addon één keer nodig om weggegooid te worden.

- Een **positieve** bevinding ("er zit een Gold-enchant op") mag onmiddellijk getoond
  worden. Die kan niet uit ontbrekende data ontstaan.
- Een **negatieve** bevinding ("geen enchant", "leeg socket") wordt pas `bad` als
  `confirmations >= 2` voor dat slot, dus na twee aparte passes met dezelfde fingerprint.
  Daarvoor is de toestand `unknown`.
- Een niet-herkend bonus-ID-patroon is `unknown`, **nooit** "geen track" of
  "volledig geüpgraded".
- Data uit de cache die ouder is dan de TTL wordt `stale` en visueel gedimd — nooit
  identiek gerenderd aan een verse scan.
- Draait het spel op een nieuwere build dan `Data/Build.lua`, dan degradeert alles wat van
  de gegenereerde tabellen afhangt naar `unknown`. Verouderde data mag stil worden,
  nooit stil fout.

### Toestandsmachine per speler

```
unseen ──▶ queued ──▶ inflight ──┬─▶ hydrating ──▶ partial ──▶ confirmed ──▶ stale
   ▲          ▲                  │                    │            │           │
   │          └──────────────────┘ timeout            └────────────┴───────────┘
   │                              (backoff, retry)         herbevestiging
   └──────────────────────── unreachable (N opeenvolgende timeouts)
```

"Klaar" bestaat niet. Een speler blijft in rotatie tot elk slot bevestigd is, en gaat
daarna naar een trage herbevestigingscadans.

---

## 7. Scanner

- **Budget.** Maximaal 6 requests per 10 seconden; de addon houdt **5 per 10 s** aan omdat
  het budget gedeeld wordt met andere addons en met handmatige inspects. Bij een timeout:
  exponentiële backoff en een retry-cap per speler per pass, anders verhongeren twee
  inspect-addons elkaar eindeloos.

  | Waarde | Standaard |
  |---|---|
  | Requestbudget | 5 per 10 s |
  | Timeout per request | 3 s |
  | Backoff | ×2 per opeenvolgende timeout, plafond 60 s |
  | Retry-cap per speler per pass | 3 |
  | `unreachable` na | 5 opeenvolgende timeouts |
  | Herbevestigingscadans na `confirmed` | elke 10 min |
- **Range-filter.** `UnitInRange` (werkt wel in combat voor groepsleden) plus
  `CanInspect(unit)` als voorfilter. Een `INSPECT_READY`-timeout is het echte
  out-of-range-signaal. `CheckInteractDistance` wordt niet gebruikt.
- **Contentie.** Elke `INSPECT_READY` wordt op GUID gematcht tegen de eigen openstaande
  request. Events van andere addons worden **wel** uitgelezen — dat is gratis dekking.
  De queue pauzeert zolang Blizzards `InspectFrame` zichtbaar is, en `ClearInspectPlayer()`
  wordt alleen aangeroepen als dat venster dicht is.
- **Synchroon oogsten.** `GetInventoryItemLink(unit, slot)` is alleen geldig tot de volgende
  `NotifyInspect` of `ClearInspectPlayer`. Alle zestien slots worden dus binnen de
  `INSPECT_READY`-handler uitgelezen. De unit-token wordt op dat moment opgehaald met
  `UnitTokenFromGUID` — raid-indices verschuiven tussen request en antwoord.
- **Spec.** `GetInspectSpecialization(unit)` is pas geldig na `INSPECT_READY`; daar vastleggen.
- **Kruiscontrole.** `C_PaperDollInfo.GetInspectItemLevel(unit)` wordt vergeleken met het
  zelf berekende gemiddelde. Wijkt het af, dan klopt de parser of de ilvl-berekening niet.
- **Combat.** De scanner pauzeert hard op `PLAYER_REGEN_DISABLED` en `ENCOUNTER_START`.
  Scannen tijdens een encounter levert niets op en Blizzard schroeft addon-gedrag in combat
  actief verder dicht.

---

## 8. Regels en beleid

### Curatielijsten (`Policy.lua`, Midnight seizoen 1)

| Lijst | Slots |
|---|---|
| Enchantbaar | helm, shoulders, chest, legs (spellthread), boots, ring 1, ring 2, wapens |
| Socket toe te voegen | helm, bracers, riem |
| Tier | helm, shoulders, chest, handen, benen |

### Zwaarte

**Fout** — leeg gear-slot; ontbrekende enchant op een enchantbaar slot; leeg socket.

**Waarschuwing** — Silver in plaats van Gold enchant of gem; socket-baar slot zonder socket;
openstaande upgrades; tier onder 5/5; minder dan 2 embellishments.

**Onbekend** — bonus-ID-patroon niet herkend; item nog niet uit de cache geladen; minder dan
twee bevestigingen.

### Randgevallen die anders valse meldingen geven

- Een tweehandig wapen maakt een lege off-hand **correct**. Geen bevinding.
- Crafted gear heeft **geen** upgrade track. Niet melden als "0 upgrades open".
- De track-noemer verschilt per track en per seizoen. `/6` hardcoden gaat mis.
- Lege sockets = totaal aantal sockets − gems in de link, met de dubbele-uitlezingsregel,
  want gem-payload loopt achter.

### Bronnen per check

| Check | Primaire bron | Fallback / kruiscontrole |
|---|---|---|
| Item level | `C_Item.GetDetailedItemLevelInfo` | `C_PaperDollInfo.GetInspectItemLevel` |
| Enchant | `enchantID` uit de link | — |
| Enchantkwaliteit | `Data/Enchants.lua` | — |
| Socketcount | `C_Item.GetItemStats` (`EMPTY_SOCKET_*`) | DB2-afleiding als testoracle |
| Gems | `gemIDs` uit de link | — |
| Upgrade track | `C_TooltipInfo.GetHyperlink`, patroon opgebouwd uit Blizzards globale string | `Data/UpgradeTracks.lua` |
| Tier | `setID` uit `GetItemInfo` (16e return) | — |
| Embellishments | bonus-ID's uit de link | — |

De tooltip is bewust de **primaire** bron voor de upgrade track: die overleeft een
seizoenswissel zonder enig onderhoud, terwijl bonus-ID's per seizoen opnieuw uitgegeven
worden. Het patroon wordt uit de globale string opgebouwd zodat het ook op een niet-Engelse
client werkt.

---

## 9. UI

Eén scrollframe met maximaal dertig rijen. Per rij: klassegekleurde naam, gemiddeld ilvl,
zestien slotcellen, en rechts een samenvattingskolom met aantal en zwaarte van de problemen.
Standaard wordt op die kolom gesorteerd, zodat de speler die aandacht nodig heeft bovenaan
staat.

- Cellen zijn texturen uit één frame-pool, met één gedeelde `OnEnter`/`OnLeave` die de
  gedeelde `GameTooltip` aanstuurt. Geen `FontString` per cel.
- Alleen de rij waarvan net data binnenkwam wordt hertekend. Het raster wordt nooit in zijn
  geheel opnieuw opgebouwd per event.
- De vier celtoestanden worden onderscheiden met **vorm én kleur**. Alleen rood-groen is
  onleesbaar voor kleurenblinde gebruikers.
- Klassekleur in de naam en zwaartekleur in de cellen vechten visueel om aandacht; de cellen
  zijn het dominante kanaal en de naamkleur blijft gedempt.
- Bovenin staat permanent de dekking: *"21/30 gescand — 9 buiten range: <namen>"*. Zonder die
  regel concludeert iedere gebruiker bij de eerste blik dat de addon stuk is.
- Klik op een rij of cel opent `UI/Detail.lua` met de volledige slot-voor-slot uitsplitsing.

---

## 10. Data-generator

`tools/generate.mjs` haalt de DB2-CSV-exports van wago.tools (ItemSparse, ItemBonus,
SpellItemEnchantment en verwanten) en schrijft `Data/*.lua`. Per patch één commando.

- Elk gegenereerd bestand krijgt een build-stempel; `Data/Build.lua` bevat het buildnummer.
- De addon vergelijkt dat met `GetBuildInfo()` en degradeert bij een nieuwere gamebuild naar
  `unknown` in plaats van naar mogelijk foute conclusies.
- `Policy.lua` wordt **niet** gegenereerd. Welke enchants dit seizoen als actueel gelden en
  welke slots een socket kunnen krijgen is curatie, niet af te leiden uit DB2.
- Bestaand precedent voor de pipeline: [WowDbScripts](https://github.com/thespags/WowDbScripts).

**Onderhoudsrisico, expliciet benoemd.** Elk seizoen veranderen enchant-ID's, gem-ID's,
track-bonus-ID's, setID's, embellishment-ID's en track-noemers, en kan het CSV-schema
van wago.tools verschuiven waardoor de generator breekt. De addon is dus het meest fout in
week één van een patch — precies wanneer raidleiders hem het hardst nodig hebben. De twee
mitigaties zijn build-stempeling met degradatie naar `unknown`, en het zo klein mogelijk
houden van het gegenereerde oppervlak: `setID` in plaats van een tier-itemtabel, en de
tooltip in plaats van de track-tabel.

---

## 11. Persistentie

- SavedVariables, gesleuteld op GUID. Omvang is geen probleem: dertig spelers × zestien
  slots aan rauwe links is hooguit enkele honderden kilobytes.
- Schemaversie in het bestand. Bij een versieverschil wordt de cache verworpen in plaats van
  gemigreerd.
- Opruimen bij login: records waarvan `lastSeen` ouder is dan **30 dagen** vervallen.
  Zonder dat groeit de cache een heel seizoen door met pug-records.
- Data ouder dan **2 uur** wordt `stale`. Dat is ruim genoeg om binnen één raidavond
  bruikbaar te blijven, en kort genoeg om nooit gear van vorige week als actueel te tonen.
- Alle afgeleide waarden worden bij het laden opnieuw berekend, nooit gepersisteerd.
- Gepersisteerde data wordt uitsluitend als `stale` getoond, met leeftijd erbij. Een week
  oude gear-set die eruitziet als een verse scan is dezelfde valse-beschuldiging-fout als
  in sectie 6.

---

## 12. Tests

`LinkParser` en `Rules` draaien onder **busted** in gewone Lua, zonder WoW-client. Dat zijn
de twee modules waar de subtiele fouten zitten, en ze zijn puur juist om dit mogelijk te maken.

- **`LinkParser`** — het testcorpus bestaat bewust vooral uit crafted, embellished,
  gesocketde en tier-links, uit de live game gehaald. Een itemlink is geen vaste
  kolomsplitsing maar een geneste structuur met lengte-geprefixte lijsten gevolgd door
  key/value-modifierparen. Naïef op index parsen werkt prima op gedropte gear en breekt
  precies op de items waar checks 3 en 6 over gaan. Het corpus wordt elk seizoen ververst.
- **`Rules`** — tabelgedreven: elke `kind`, elke `severity`, en expliciet de tri-state
  logica uit sectie 6 (positief mag meteen, negatief pas na twee bevestigingen,
  onbekend bonus-ID blijft `unknown`).
- **`Scanner`** en **`UI`** blijven dun genoeg voor handmatige verificatie in-game.

---

## 13. Buiten scope

Niet haalbaar via inspect, en bewust vastgelegd zodat het er later niet insluipt:

- Great Vault-voortgang, verdiende crests, raid kills — die komen van Blizzards Armory API,
  niet uit de game-client.
- Tijdelijke wapen-enchants en oils van anderen; `GetWeaponEnchantInfo` werkt alleen voor
  jezelf en temp enchants staan niet in de itemlink.
- Consumables.
- Een versheidssignaal: er is geen event dat meldt dat een ander raidlid geregemd heeft.

Buiten scope voor versie 1, maar bewust niet uitgesloten:

- Addon-comm-kanaal voor volledige, directe data van raidleden die de addon wél hebben.
  Het `source`-veld staat er al voor klaar.
- Audit- en exportmodus buiten de raid.

---

## 14. Nog in-game te verifiëren

Deze punten zijn niet uit documentatie op te lossen en moeten tijdens implementatie
bevestigd worden:

1. Off-hand enchantbaarheid in Midnight — geldt dat voor schilden en off-hand wapens, of
   alleen voor main hand?
2. Zijn gems in Midnight ook tweetraps (Silver/Gold), net als enchants?
3. Verschijnt een spellthread op legs als een gewone `enchantID` in de itemlink?
4. Profession tools — buiten de raid-check houden, of meenemen?
5. Exacte vorm van de tooltipregel voor de upgrade track, en de bijbehorende globale string.
