# Spike-resultaten

**Uitgevoerd:** 2026-08-03, WoW retail **12.0.7**, build **68887**
**Captures:** 8 (7 spelers, 1 daarvan zowel als `player` als via inspect)
**Slots vastgelegd:** 65

---

## Beantwoorde open punten uit §14 van de spec

### §14.2 — De globale string voor de upgrade track

`ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` bestaat en heeft de waarde:

```
Upgrade Level: %s %d/%d
```

De regel verschijnt letterlijk in de tooltip van geïnspecteerde items, bijvoorbeeld
`"Upgrade Level: Myth 6/6"` en `"Upgrade Level: Myth 3/6"`. Van de 65 vastgelegde slots
hadden er **34** zo'n regel; items zonder track (zoals sommige trinkets) hebben hem niet,
wat betekent dat afwezigheid van de regel géén bewijs is van "geen upgrades open".

De tooltip-eerst strategie uit §8 is hiermee bevestigd als werkbaar.

### §14.1 — Off-hand enchantbaarheid

Eén off-hand vastgelegd: *Vexamus' Expulsion Rod*, type **Held In Off-hand**, `enchantID = 0`.
Dat bevestigt de aanname dat een off-hand die geen wapen is geen enchant hoort te hebben.

**Nog niet bevestigd:** het schildgeval. Er zat geen schild in de steekproef.

### §14.3 — Spellthread op benen

Bevestigd: benen dragen een gewone `enchantID` in de link. Drie van de drie waargenomen
beenstukken hadden er een.

---

## Socketcount: welke API?

**65 vergelijkingen, 0 verschillen.** `C_Item.GetItemStats` (som van de `EMPTY_SOCKET_*`
sleutels) en `C_Item.GetItemNumSockets` gaven op elk item hetzelfde getal.
`GetItemNumAddedSockets` bestaat eveneens en gaf overal 0 in deze steekproef.

Conclusie: de keuze maakt niet uit. `GetItemStats` blijft de primaire bron zoals de spec
zegt; `GetItemNumSockets` is een gelijkwaardig alternatief mocht dat ooit handiger blijken.

Let op: de `EMPTY_SOCKET_*` sleutels betekenen "hier zit een socket", niet "deze socket is
leeg" — de gemeten waarden bevestigen dat. Een bracer met een gevulde Prismatic Socket gaf
`fromGetItemStats = 1` terwijl er een gem in zat.

---

## Parser gevalideerd op echte data

**65 van de 65 links parseerden foutloos.** Drie dingen kwamen uit de echte data die niet
uit documentatie of redenering af te leiden waren:

1. **Het kleurvoorvoegsel is `|cnIQ4:`**, niet meer het klassieke `|cffa335ee`.
   De parser matcht op `|Hitem:` en is daar ongevoelig voor, maar een implementatie die op
   het kleurvoorvoegsel had gematcht was hier stukgelopen.
2. **Modifier-waarden kunnen negatief zijn.** `-2147480301` kwam 8 keer voor.
3. **Achter de modifiers kan een niet-numeriek veld staan**: de crafter-GUID, bijvoorbeeld
   `Player-1403-0B343557`.

Maxima in de steekproef: 9 bonus-ID's, 10 modifier-paren. De synthetische fixtures gingen
tot 5 en 3, dus de echte data is aanzienlijk complexer.

---

## Enchants per slot: het beleid gevalideerd

| Slot | Gezien | Met enchant |
|---|---|---|
| helm | 3 | **3** |
| benen | 3 | **3** |
| boots | 2 | **2** |
| chest | 4 | 3 |
| ring 1 | 7 | 5 |
| ring 2 | 6 | 4 |
| mainhand | 4 | 3 |
| shoulders | 2 | **0** |
| nek | 6 | 0 |
| riem | 3 | 0 |
| bracers | 5 | 0 |
| handen | 4 | 0 |
| trinkets | 12 | 0 |
| cloak | 3 | 0 |
| off-hand | 1 | 0 |

Nek, riem, bracers, handen, trinkets en cloak: **nul enchants op 33 waarnemingen**. Dat
bevestigt de Midnight-wijziging waarbij cloak en bracers uit de enchantbare lijst verdwenen.

De ontbrekende enchants op chest, ringen en mainhand zijn echte bevindingen — dat is precies
wat de addon hoort te melden.

### Shoulders: onderzocht en bevestigd

Shoulders zijn in deze steekproef **twee keer gezien en nul keer enchanted**, terwijl helm,
benen en boots 100% scoorden. Dat leek een aanwijzing dat `Policy/Slots.lua` shoulders ten
onrechte als enchantbaar markeert — een fout die élke raider een valse melding zou
opleveren, precies de beschuldiging waar §6 tegen ontworpen is.

Nagezocht: shoulders **zijn** wel degelijk enchantbaar in Midnight seizoen 1. Er bestaan zes
shoulder-enchants: Akil'zon's Swiftness, Amirdrassil's Grace, Flight Of The Eagle,
Nature's Grace, Silvermoon's Mending en Thalassian Recovery.

Het beleid blijft dus ongewijzigd, en de twee waargenomen spelers misten werkelijk een
shoulder-enchant. Dat is een echte bevinding, geen valse.

---

## Belangrijkste bevinding: inspects zijn veel incompleter dan aangenomen

| Capture | Slots teruggekregen |
|---|---|
| `player` (eigen uitrusting) | 15 |
| inspect:Needmoarmist | 15 |
| inspect:Heresysaînt | 11 |
| inspect:Narrona | 7 |
| inspect:Sambahirvi | 6 |
| inspect:Mosiow | 6 |
| inspect:Uríeqt | 3 |
| inspect:Zylirie | 2 |

Een volledig uitgeruste raider heeft 15 of 16 gevulde slots. Slechts **twee van de acht**
captures leverden dat op; de rest gaf 2 tot 11 slots terug. `GetInventoryItemLink` gaf voor
de overige slots simpelweg `nil`.

Dit is ernstiger dan §3 van de spec aannam. Daar staat dat de *payload* van een link kan
ontbreken; in werkelijkheid ontbreken **hele slots**. Een implementatie die een ontbrekend
slot als "leeg gear-slot" leest, produceert bij de eerste inspect een muur van valse
foutmeldingen.

Het huidige vertrouwensmodel vangt dit al af: `missing_item` vereist bevestigd `itemLoaded`-
bewijs, en dat bewijs ontstaat niet voor een slot dat nooit is teruggekomen. De toestand
blijft dus `unknown` in plaats van `bad`. Maar er volgt wel een consequentie voor deel 2:

1. **De scanner moet per pass vastleggen hoeveel slots hij kreeg.** Een pass met 2 slots is
   geen bewijs van iets; een pass met 15 wel.
2. **`Rules` moet "slot ontbrak in deze pass" kunnen onderscheiden van "speler draagt hier
   niets".** Nu produceert elk ontbrekend slot een `unknown`-bevinding, wat correct maar
   ruisend is: 14 grijze vakjes per speler bij de eerste pass.
3. **De doorrekening in §7 was te optimistisch.** Twee passes van 60 seconden leveren geen
   bevestigde speler op als elke pass maar een deel van de slots teruggeeft. Realistisch
   zijn er meer passes nodig, en de opbouwfase in de UI duurt navenant langer.
