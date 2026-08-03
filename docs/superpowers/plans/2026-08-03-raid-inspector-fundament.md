# Raid Inspector — Implementatieplan, deel 1: fundament

> **Voor agentic workers:** VERPLICHTE SUB-SKILL: gebruik superpowers:subagent-driven-development (aanbevolen) of superpowers:executing-plans om dit plan taak voor taak uit te voeren. Stappen gebruiken checkbox-syntax (`- [ ]`) voor tracking.

**Doel:** De pure kern van de addon bouwen — itemlink-parser, bewijsadministratie, beleid en regels — plus een wegwerp-spike die in-game de drie onzekere aannames beantwoordt waar de rest van het ontwerp op rust.

**Architectuur:** Modules zijn platte Lua-bestanden die via de WoW-addon-namespace (`local addonName, ns = ...`) een gedeelde tabel vullen. `LinkParser`, `Evidence` en `Rules` raken geen enkele WoW-API aan en draaien daardoor onder een kale Lua 5.1-interpreter buiten de game. De testharnas laadt ze met `loadfile` en geeft dezelfde twee argumenten mee als WoW doet, zodat de laadvorm identiek is.

**Tech stack:** Lua 5.1.5 (PUC, prebuilt binary in `tools/lua/`), eigen minimale testrunner zonder dependencies, PowerShell voor orkestratie. Node is aanwezig maar wordt pas in deel 2 gebruikt voor de datagenerator.

## Scope van dit plan

Dit plan dekt stap 1 tot en met 3 van §15 van de spec. `Scanner`, `Hydrator`, `UpgradeTrackAdapter`, `Cache`, UI en de generator vallen in **deel 2**, dat pas geschreven wordt als de spike van taak 4 zijn antwoorden heeft opgeleverd. Beide reviewers wezen op dezelfde afhankelijkheidsval: `Rules` schrijven tegen een aangenomen recordvorm terwijl de invoer van de `Hydrator` juist het onzekerst is. Daarom stoppen de regels in dit plan bij de checks die géén socketcount of tooltipdata nodig hebben.

Concreet betekent dat: `missing_item`, `missing_enchant`, `low_enchant`, `outdated_enchant`, `low_gem`, `outdated_gem`, `tier_incomplete` en `embellishments_missing` zitten in dit plan. `empty_socket`, `missing_socket` en `upgrades_left` komen in deel 2.

## Globale constraints

- **Doelruntime is Lua 5.1**, niet 5.4. Verboden in alle addon-code: `goto`, `//`, native bitwise operators (`&`, `|`, `~`, `<<`, `>>`), `\z` in strings, `table.unpack` (gebruik `unpack`), `os.exit` met booleaanse tweede parameter.
- **Geen WoW-globals in pure modules.** `strsplit`, `format`, `tinsert`, `wipe`, `strsub` en verwanten bestaan alleen in de game. De testharnas shimt ze bewust **niet**; hun afwezigheid is de purity-check.
- **Geen `#` op tabellen met gaten.** `gemIDs` is een array van vier met mogelijk lege plekken; tel expliciet, gebruik nooit `#`.
- **Geen aannames over integer-breedte.** Alle rekenkunde blijft onder 2^53 zodat 5.1-doubles en 5.4-integers hetzelfde resultaat geven.
- **Doelversie van het spel:** retail Midnight (12.0), seizoen 1.
- Addon-mapnaam en namespace: `RaidInspector`.
- Alle bronbestanden LF-eol, UTF-8 zonder BOM.

## Referenties

- Spec: `docs/superpowers/specs/2026-08-03-raid-inspector-design.md`
- WoW AddOns-map op deze machine: `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns`

---

### Taak 1: Toolchain, testrunner en repo-skelet

**Bestanden:**
- Aanmaken: `tools/lua/lua5.1.exe` (binary, al aanwezig — stap 1 verifieert)
- Aanmaken: `tools/run-tests.lua`
- Aanmaken: `tools/test.ps1`
- Aanmaken: `spec/helper.lua`
- Aanmaken: `spec/harness_spec.lua`
- Aanmaken: `.gitattributes`
- Aanmaken: `.gitignore`

**Interfaces:**
- Levert: `spec/helper.lua` exporteert `helper.loadModules(paths)` die een verse namespace-tabel `ns` teruggeeft nadat de opgegeven addon-bestanden erin geladen zijn. Alle latere taken gebruiken dit om modules te laden.
- Levert: globale testfuncties `describe(name, fn)`, `it(name, fn)`, `before_each(fn)` en de aanroepbare asserttabel `assert` met `.equals`, `.same`, `.truthy`, `.falsy`, `.matches`, `.is_nil`.

- [ ] **Stap 1: Verifieer de Lua-binary**

De binary is al gedownload naar `tools/lua/`. Controleer dat hij draait en dat het écht 5.1 is:

```powershell
& "tools\lua\lua5.1.exe" -v
& "tools\lua\lua5.1.exe" -e "print(_VERSION, type(unpack), type(table.unpack))"
```

Verwacht:
```
Lua 5.1.5  Copyright (C) 1994-2012 Lua.org, PUC-Rio
Lua 5.1	function	nil
```

Ontbreekt de binary, haal hem dan opnieuw op:

```powershell
$zip = "$env:TEMP\lua515.zip"
Invoke-WebRequest -Uri "https://master.dl.sourceforge.net/project/luabinaries/5.1.5/Tools%20Executables/lua-5.1.5_Win64_bin.zip?viasf=1" -OutFile $zip -UseBasicParsing -Headers @{ "User-Agent" = "Mozilla/5.0" }
Expand-Archive -Path $zip -DestinationPath "tools\lua" -Force
```

Let op: `downloads.sourceforge.net` levert een HTML-tussenpagina in plaats van de zip. Gebruik `master.dl.sourceforge.net` met de `?viasf=1` parameter.

- [ ] **Stap 2: Schrijf de testrunner**

Aanmaken `tools/run-tests.lua`:

```lua
-- Minimale testrunner voor Lua 5.1. Geen dependencies, bewust klein gehouden.
-- Aanroep: lua5.1.exe tools/run-tests.lua [--filter=PATROON] <specbestand>...

local argv = {...}
local filter, files = nil, {}
for i = 1, table.getn(argv) do
  local a = argv[i]
  local f = string.match(a, "^%-%-filter=(.*)$")
  if f then filter = f else files[table.getn(files) + 1] = a end
end

local builtinAssert = assert
local passed, failed, failures = 0, 0, {}
local currentDescribe, currentBeforeEach = nil, nil

-- Diepe gelijkheid die het afwijkende sleutelpad teruggeeft. Dit is het enige
-- stuk van de runner dat echt goed moet zijn: bevindingenlijsten zijn geneste
-- tabellen en "ze zijn ongelijk" is dan een nutteloze foutmelding.
local function deepEqual(a, b, path)
  path = path or "<root>"
  if type(a) ~= type(b) then
    return false, path .. ": type " .. type(a) .. " vs " .. type(b)
  end
  if type(a) ~= "table" then
    if a ~= b then
      return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b)
    end
    return true
  end
  for k, v in pairs(a) do
    local ok, p = deepEqual(v, b[k], path .. "." .. tostring(k))
    if not ok then return false, p end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false, path .. "." .. tostring(k) .. ": ontbreekt in verwachte waarde"
    end
  end
  return true
end

local A = setmetatable({}, {
  __call = function(_, ...) return builtinAssert(...) end,
})

function A.equals(expected, actual, msg)
  if expected ~= actual then
    error((msg or "equals") .. ": verwacht " .. tostring(expected)
          .. ", kreeg " .. tostring(actual), 2)
  end
end

function A.same(expected, actual, msg)
  local ok, path = deepEqual(expected, actual)
  if not ok then
    error((msg or "same") .. ": verschil bij " .. path, 2)
  end
end

function A.truthy(v, msg)
  if not v then error((msg or "truthy") .. ": kreeg " .. tostring(v), 2) end
end

function A.falsy(v, msg)
  if v then error((msg or "falsy") .. ": kreeg " .. tostring(v), 2) end
end

function A.is_nil(v, msg)
  if v ~= nil then error((msg or "is_nil") .. ": kreeg " .. tostring(v), 2) end
end

function A.matches(pattern, s, msg)
  if type(s) ~= "string" or not string.find(s, pattern) then
    error((msg or "matches") .. ": " .. tostring(s) .. " voldoet niet aan " .. pattern, 2)
  end
end

assert = A
describe = function(name, fn)
  local previousDescribe, previousBefore = currentDescribe, currentBeforeEach
  currentDescribe, currentBeforeEach = name, nil
  fn()
  currentDescribe, currentBeforeEach = previousDescribe, previousBefore
end

before_each = function(fn) currentBeforeEach = fn end

it = function(name, fn)
  local full = (currentDescribe and (currentDescribe .. " > ") or "") .. name
  if filter and not string.find(full, filter, 1, true) then return end
  local before = currentBeforeEach
  local ok, err = xpcall(function()
    if before then before() end
    fn()
  end, function(e) return debug.traceback(tostring(e), 2) end)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    failures[table.getn(failures) + 1] = { name = full, err = err }
  end
end

-- Vanaf hier is het schrijven naar een global een fout. Per ongeluk een global
-- aanmaken is in WoW-addons een klassieke bug: je vervuilt de gedeelde
-- namespace van de hele client. Buiten de game is dat gratis te vangen.
setmetatable(_G, {
  __newindex = function(_, k)
    error("verboden global aangemaakt: " .. tostring(k) .. " (gebruik local)", 2)
  end,
})

for i = 1, table.getn(files) do
  local chunk, loadErr = loadfile(files[i])
  if not chunk then
    failed = failed + 1
    failures[table.getn(failures) + 1] = { name = files[i], err = "laadfout: " .. tostring(loadErr) }
  else
    local ok, err = xpcall(chunk, function(e) return debug.traceback(tostring(e), 2) end)
    if not ok then
      failed = failed + 1
      failures[table.getn(failures) + 1] = { name = files[i], err = err }
    end
  end
end

for i = 1, table.getn(failures) do
  print("")
  print("FAAL: " .. failures[i].name)
  print(failures[i].err)
end

print("")
print(string.format("%d geslaagd, %d gefaald", passed, failed))
if failed > 0 then os.exit(1) end
os.exit(0)
```

Waarom `table.getn` en niet `#`: beide werken in 5.1, maar `table.getn` is expliciet en maakt duidelijk dat er nergens op lengte van tabellen met gaten wordt vertrouwd. In de addon-code zelf gebruik je `#` alleen op dichte arrays.

- [ ] **Stap 3: Schrijf het PowerShell-wrapperscript**

De globbing gebeurt in PowerShell, niet in Lua — Lua 5.1 heeft geen directory-listing zonder `luafilesystem`, en dat vereist een C-compiler.

Aanmaken `tools/test.ps1`:

```powershell
param([string]$Filter = "")

$root    = Split-Path -Parent $PSScriptRoot
$lua     = Join-Path $PSScriptRoot "lua\lua5.1.exe"
$runner  = Join-Path $PSScriptRoot "run-tests.lua"
$specDir = Join-Path $root "spec"

$specs = Get-ChildItem -Path $specDir -Filter "*_spec.lua" -Recurse |
         ForEach-Object { $_.FullName }

if (-not $specs) { Write-Host "Geen specbestanden gevonden in $specDir"; exit 1 }

$luaArgs = @($runner)
if ($Filter -ne "") { $luaArgs += "--filter=$Filter" }
$luaArgs += $specs

# De werkmap moet de repo-root zijn: specbestanden doen dofile("spec/helper.lua")
# met een relatief pad, en dat moet werken ongeacht waar je het script aanroept.
Push-Location $root
try { & $lua $luaArgs; $code = $LASTEXITCODE } finally { Pop-Location }
exit $code
```

- [ ] **Stap 4: Schrijf de testhelper**

Aanmaken `spec/helper.lua`:

```lua
-- Laadt addon-modules precies zoals WoW dat doet: elk bestand is een chunk die
-- twee argumenten krijgt, de addonnaam en een gedeelde namespace-tabel. Door
-- dezelfde vorm te gebruiken kan een module die stiekem een WoW-global aanraakt
-- hier niet ongemerkt doorheen glippen.

local helper = {}

local function repoRoot()
  local dir = string.match(debug.getinfo(1, "S").source, "^@(.*)[/\\]spec[/\\]helper%.lua$")
  return dir or "."
end

function helper.loadModules(paths)
  local ns = {}
  for i = 1, table.getn(paths) do
    local full = repoRoot() .. "/" .. paths[i]
    local chunk = assert(loadfile(full), "kon niet laden: " .. full)
    chunk("RaidInspector", ns)
  end
  return ns
end

return helper
```

- [ ] **Stap 5: Schrijf de falende harnastest**

Aanmaken `spec/harness_spec.lua`:

```lua
describe("testharnas", function()
  it("draait onder Lua 5.1", function()
    assert.equals("Lua 5.1", _VERSION)
  end)

  it("heeft unpack als global en geen table.unpack", function()
    assert.equals("function", type(unpack))
    assert.is_nil(table.unpack)
  end)

  it("vergelijkt geneste tabellen en noemt het afwijkende pad", function()
    local ok, err = pcall(function()
      assert.same({ a = { b = 1 } }, { a = { b = 2 } })
    end)
    assert.falsy(ok)
    assert.matches("%.a%.b", err)
  end)

  it("laadt een module met de addon-namespace", function()
    local helper = dofile("spec/helper.lua")
    local ns = helper.loadModules({ "RaidInspector/Nonexistent.lua" })
    assert.truthy(ns)
  end)
end)
```

- [ ] **Stap 6: Draai de tests en verifieer dat de laatste faalt**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

Verwacht: de eerste drie tests slagen, de vierde faalt met "kon niet laden" omdat `RaidInspector/Nonexistent.lua` niet bestaat. Exitcode 1.

- [ ] **Stap 7: Vervang de laatste test door een echte module**

Aanmaken `RaidInspector/Version.lua`:

```lua
local addonName, ns = ...

ns.VERSION = "0.1.0"
```

Vervang in `spec/harness_spec.lua` de vierde test door:

```lua
  it("laadt een module met de addon-namespace", function()
    local helper = dofile("spec/helper.lua")
    local ns = helper.loadModules({ "RaidInspector/Version.lua" })
    assert.equals("0.1.0", ns.VERSION)
  end)
```

- [ ] **Stap 8: Draai de tests en verifieer dat alles slaagt**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

Verwacht: `4 geslaagd, 0 gefaald`, exitcode 0.

- [ ] **Stap 9: Repo-hygiëne**

Aanmaken `.gitattributes`:

```
* text=auto eol=lf
*.exe binary
*.dll binary
*.zip binary
```

Aanmaken `.gitignore`:

```
*.zip
.vscode/
```

De Lua-binary en de bijbehorende DLL's worden **wel** ingecheckt: ze zijn onderdeel van de toolchain en zonder hen draait geen enkele test.

- [ ] **Stap 10: Commit**

```powershell
git add tools spec RaidInspector .gitattributes .gitignore
git commit -m "feat: Lua 5.1 toolchain en minimale testrunner"
```

---

### Taak 2: LinkParser — vaste velden

**Bestanden:**
- Aanmaken: `RaidInspector/LinkParser.lua`
- Aanmaken: `spec/LinkParser_spec.lua`
- Aanmaken: `spec/fixtures/links.lua`

**Interfaces:**
- Verbruikt: `helper.loadModules` uit taak 1.
- Levert: `ns.LinkParser.parse(link)` geeft `nil` terug voor onbruikbare invoer, anders een tabel met velden `itemID`, `enchantID`, `gemIDs` (array van vier getallen, 0 waar leeg), `gemCount`, `suffixID`, `linkLevel`, `specID`, `itemContext`. Latere taken breiden dezelfde tabel uit met `bonusIDs` en `modifiers`.

- [ ] **Stap 1: Leg het linkformaat vast in fixtures**

Aanmaken `spec/fixtures/links.lua`:

```lua
-- Itemlink-structuur (retail):
--   item:itemID:enchantID:gem1:gem2:gem3:gem4:suffixID:uniqueID:linkLevel
--       :specID:modifiersMask:itemContext:numBonusIDs:bonus...:numModifiers
--       :modType1:modValue1:...
--
-- LET OP: deze fixtures zijn SYNTHETISCH. Ze zijn structureel correct maar de
-- ID's zijn verzonnen. Taak 4 vervangt ze door echte links uit Midnight.

return {
  -- Ring met enchant en één gem, drie bonus-ID's, één modifier-paar.
  ringWithEnchantAndGem =
    "|cffa335ee|Hitem:211018:7364:213743::::::80:268:0:6:3:10421:9633:8902:1:28:2462|h[Testring]|h|r",

  -- Chest zonder enchant en zonder gems, één bonus-ID, geen modifiers.
  chestBare =
    "|cffa335ee|Hitem:212446::::::::80:268::11:1:10356:0|h[Testborst]|h|r",

  -- Kaal item: alleen een itemID, alle overige velden leeg.
  minimal =
    "|cffffffff|Hitem:6948::::::::80:268::::|h[Hearthstone]|h|r",

  -- Alleen het item-gedeelte, zonder kleurcode of naam.
  plainPayload =
    "item:211018:7364:213743::::::80:268:0:6:3:10421:9633:8902:1:28:2462",

  notAnItem =
    "|cff71d5ff|Hspell:12345|h[Een spreuk]|h|r",
}
```

- [ ] **Stap 2: Schrijf de falende tests**

Aanmaken `spec/LinkParser_spec.lua`:

```lua
local helper = dofile("spec/helper.lua")
local links  = dofile("spec/fixtures/links.lua")

local function parser()
  return helper.loadModules({ "RaidInspector/LinkParser.lua" }).LinkParser
end

describe("LinkParser vaste velden", function()
  it("leest itemID, enchantID en gems uit een volledige link", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.equals(211018, r.itemID)
    assert.equals(7364, r.enchantID)
    assert.same({ 213743, 0, 0, 0 }, r.gemIDs)
    assert.equals(1, r.gemCount)
  end)

  it("geeft nul terug voor lege velden in plaats van nil", function()
    local r = parser().parse(links.chestBare)
    assert.equals(212446, r.itemID)
    assert.equals(0, r.enchantID)
    assert.same({ 0, 0, 0, 0 }, r.gemIDs)
    assert.equals(0, r.gemCount)
  end)

  it("leest linkLevel, specID en itemContext", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.equals(80, r.linkLevel)
    assert.equals(268, r.specID)
    assert.equals(6, r.itemContext)
  end)

  it("accepteert een kale payload zonder kleurcode", function()
    local r = parser().parse(links.plainPayload)
    assert.equals(211018, r.itemID)
    assert.equals(7364, r.enchantID)
  end)

  it("verwerkt een minimale link zonder te crashen", function()
    local r = parser().parse(links.minimal)
    assert.equals(6948, r.itemID)
    assert.equals(0, r.enchantID)
  end)

  it("geeft nil voor een niet-item hyperlink", function()
    assert.is_nil(parser().parse(links.notAnItem))
  end)

  it("geeft nil voor nil en voor een lege string", function()
    assert.is_nil(parser().parse(nil))
    assert.is_nil(parser().parse(""))
  end)
end)
```

- [ ] **Stap 3: Draai de tests en verifieer dat ze falen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "LinkParser"
```

Verwacht: zeven failures met "kon niet laden: .../RaidInspector/LinkParser.lua".

- [ ] **Stap 4: Schrijf de minimale implementatie**

Aanmaken `RaidInspector/LinkParser.lua`:

```lua
local addonName, ns = ...

local LinkParser = {}
ns.LinkParser = LinkParser

-- Splitst de payload op dubbele punten en behoudt lege velden. Het toevoegen
-- van een afsluitende ":" zorgt dat ook het laatste veld gevonden wordt.
local function splitFields(payload)
  local fields, n = {}, 0
  for field in string.gmatch(payload .. ":", "([^:]*):") do
    n = n + 1
    fields[n] = field
  end
  fields.n = n
  return fields
end

local function num(fields, index)
  return tonumber(fields[index]) or 0
end

function LinkParser.parse(link)
  if type(link) ~= "string" or link == "" then return nil end

  local payload = string.match(link, "|Hitem:([^|]+)|h")
                  or string.match(link, "^item:(.+)$")
  if not payload then return nil end

  local f = splitFields(payload)
  if num(f, 1) == 0 then return nil end

  local gemIDs = { num(f, 3), num(f, 4), num(f, 5), num(f, 6) }
  local gemCount = 0
  for i = 1, 4 do
    if gemIDs[i] ~= 0 then gemCount = gemCount + 1 end
  end

  return {
    itemID      = num(f, 1),
    enchantID   = num(f, 2),
    gemIDs      = gemIDs,
    gemCount    = gemCount,
    suffixID    = num(f, 7),
    linkLevel   = num(f, 9),
    specID      = num(f, 10),
    itemContext = num(f, 12),
    _fields     = f,
  }
end
```

`gemCount` bestaat juist omdat `#gemIDs` op een array met nullen niets betekenisvols zegt; de globale constraint verbiedt dat patroon.

- [ ] **Stap 5: Draai de tests en verifieer dat ze slagen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "LinkParser"
```

Verwacht: `7 geslaagd, 0 gefaald`.

- [ ] **Stap 6: Commit**

```powershell
git add RaidInspector/LinkParser.lua spec/LinkParser_spec.lua spec/fixtures/links.lua
git commit -m "feat: LinkParser leest de vaste velden van een itemlink"
```

---

### Taak 3: LinkParser — bonus-ID's en modifiers

**Bestanden:**
- Wijzigen: `RaidInspector/LinkParser.lua`
- Wijzigen: `spec/LinkParser_spec.lua`
- Wijzigen: `spec/fixtures/links.lua`

**Interfaces:**
- Levert: dezelfde tabel uit `LinkParser.parse` krijgt er `bonusIDs` (dichte array van getallen, leeg als er geen zijn) en `modifiers` (map van modifiertype naar waarde) bij. `_fields` verdwijnt uit de publieke vorm.

Dit is de taak waar naïef parsen breekt. De bonus-ID-lijst is lengte-geprefixt, en daarachter staat een tweede lengte-geprefixte lijst met paren. Wie op vaste indices parseert krijgt gedropte gear goed en crafted gear fout — precies de items waar de enchant- en embellishment-checks over gaan.

- [ ] **Stap 1: Voeg fixtures toe voor de lastige gevallen**

Toevoegen aan `spec/fixtures/links.lua`, binnen de bestaande tabel:

```lua
  -- Crafted item: vijf bonus-ID's, drie modifier-paren (crafting quality,
  -- crafter-GUID-verwijzing en een gewijzigd reagent).
  craftedEmbellished =
    "|cffa335ee|Hitem:222817::::::::80:268::11:5:10421:9633:8902:11144:1533:3:28:2462:38:8:40:12|h[Gesmede handschoenen]|h|r",

  -- Item zonder bonus-ID's maar mét modifiers.
  noBonusWithModifiers =
    "|cffa335ee|Hitem:219342::::::::80:268::4:0:1:28:2400|h[Testketting]|h|r",

  -- Item met bonus-ID's maar zonder modifiers.
  bonusNoModifiers =
    "|cffa335ee|Hitem:212446::::::::80:268::11:2:10356:9888:0|h[Testschouders]|h|r",
```

- [ ] **Stap 2: Schrijf de falende tests**

Toevoegen aan `spec/LinkParser_spec.lua`, na het bestaande describe-blok:

```lua
describe("LinkParser bonus-IDs en modifiers", function()
  it("leest een lengte-geprefixte bonuslijst", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.same({ 10421, 9633, 8902 }, r.bonusIDs)
  end)

  it("leest modifier-paren als een map van type naar waarde", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.same({ [28] = 2462 }, r.modifiers)
  end)

  it("parseert crafted gear met vijf bonussen en drie modifiers", function()
    local r = parser().parse(links.craftedEmbellished)
    assert.same({ 10421, 9633, 8902, 11144, 1533 }, r.bonusIDs)
    assert.same({ [28] = 2462, [38] = 8, [40] = 12 }, r.modifiers)
  end)

  it("gaat om met nul bonussen gevolgd door modifiers", function()
    local r = parser().parse(links.noBonusWithModifiers)
    assert.same({}, r.bonusIDs)
    assert.same({ [28] = 2400 }, r.modifiers)
  end)

  it("gaat om met bonussen gevolgd door nul modifiers", function()
    local r = parser().parse(links.bonusNoModifiers)
    assert.same({ 10356, 9888 }, r.bonusIDs)
    assert.same({}, r.modifiers)
  end)

  it("geeft lege tabellen als de link vroegtijdig eindigt", function()
    local r = parser().parse(links.minimal)
    assert.same({}, r.bonusIDs)
    assert.same({}, r.modifiers)
  end)

  it("legt geen interne velden bloot", function()
    local r = parser().parse(links.ringWithEnchantAndGem)
    assert.is_nil(r._fields)
  end)
end)
```

- [ ] **Stap 3: Draai de tests en verifieer dat ze falen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "bonus-IDs"
```

Verwacht: zeven failures, de eerste met "verschil bij <root>.1" of een nil-index fout.

- [ ] **Stap 4: Breid de implementatie uit**

Vervang in `RaidInspector/LinkParser.lua` het `return`-blok van `LinkParser.parse` door:

```lua
  local bonusIDs, modifiers = {}, {}

  local bonusCount = num(f, 13)
  for i = 1, bonusCount do
    bonusIDs[i] = num(f, 13 + i)
  end

  local modCountIndex = 13 + bonusCount + 1
  local modCount = num(f, modCountIndex)
  for i = 1, modCount do
    local typeIndex  = modCountIndex + (i - 1) * 2 + 1
    local valueIndex = typeIndex + 1
    local modType = num(f, typeIndex)
    if modType ~= 0 then
      modifiers[modType] = num(f, valueIndex)
    end
  end

  return {
    itemID      = num(f, 1),
    enchantID   = num(f, 2),
    gemIDs      = gemIDs,
    gemCount    = gemCount,
    suffixID    = num(f, 7),
    linkLevel   = num(f, 9),
    specID      = num(f, 10),
    itemContext = num(f, 12),
    bonusIDs    = bonusIDs,
    modifiers   = modifiers,
  }
```

Merk op dat `modCount` het aantal *paren* telt, niet het aantal velden. Dat verschil is de meest gemaakte fout bij dit formaat.

- [ ] **Stap 5: Draai alle tests en verifieer dat ze slagen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

Verwacht: `18 geslaagd, 0 gefaald`.

- [ ] **Stap 6: Commit**

```powershell
git add RaidInspector/LinkParser.lua spec/LinkParser_spec.lua spec/fixtures/links.lua
git commit -m "feat: LinkParser leest bonus-IDs en modifier-paren"
```

---

### Taak 4: Spike-addon voor in-game verificatie

**Bestanden:**
- Aanmaken: `spike/RaidInspectorSpike/RaidInspectorSpike.toc`
- Aanmaken: `spike/RaidInspectorSpike/Spike.lua`
- Aanmaken: `tools/deploy-spike.ps1`
- Aanmaken: `docs/superpowers/spike-resultaten.md`

**Interfaces:**
- Levert: een tekstbestand met echte Midnight-itemlinks dat taak 2 en 3 hun synthetische fixtures laat vervangen, plus antwoorden op de drie onzekere aannames uit §15 van de spec en de twee open punten uit §14.

Dit is een **wegwerpaddon**. Hij hoeft niet mooi te zijn en wordt na deel 2 verwijderd. Zijn enige doel is meten wat niet uit documentatie te halen is.

- [ ] **Stap 1: Schrijf het TOC-bestand**

Aanmaken `spike/RaidInspectorSpike/RaidInspectorSpike.toc`:

```
## Interface: 120000
## Title: Raid Inspector Spike
## Notes: Wegwerpaddon om aannames te verifieren. Niet distribueren.
## SavedVariables: RaidInspectorSpikeDB

Spike.lua
```

Klopt het interface-nummer niet, corrigeer het dan met de uitvoer van `/dump select(4, GetBuildInfo())` in-game.

- [ ] **Stap 2: Schrijf de spike**

Aanmaken `spike/RaidInspectorSpike/Spike.lua`:

```lua
local addonName, ns = ...

RaidInspectorSpikeDB = RaidInspectorSpikeDB or {}

local SLOTS = {
  1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17,
}

local function dumpGlobalString()
  local out = {}
  out.exists = (ITEM_UPGRADE_TOOLTIP_FORMAT_STRING ~= nil)
  out.value  = ITEM_UPGRADE_TOOLTIP_FORMAT_STRING
  return out
end

-- Vergelijkt de twee kandidaat-APIs voor socketcount op hetzelfde item.
local function socketSources(link)
  local result = {}

  local stats = C_Item.GetItemStats and C_Item.GetItemStats(link)
  if stats then
    local n = 0
    for key, value in pairs(stats) do
      if string.find(key, "EMPTY_SOCKET") then n = n + value end
    end
    result.fromGetItemStats = n
  else
    result.fromGetItemStats = "nil"
  end

  if C_Item.GetItemNumSockets then
    local ok, v = pcall(C_Item.GetItemNumSockets, link)
    result.fromGetItemNumSockets = ok and v or ("fout: " .. tostring(v))
  else
    result.fromGetItemNumSockets = "API bestaat niet"
  end

  if C_Item.GetItemNumAddedSockets then
    local ok, v = pcall(C_Item.GetItemNumAddedSockets, link)
    result.fromGetItemNumAddedSockets = ok and v or ("fout: " .. tostring(v))
  else
    result.fromGetItemNumAddedSockets = "API bestaat niet"
  end

  return result
end

local function tooltipLines(link)
  if not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
    return { error = "C_TooltipInfo.GetHyperlink bestaat niet" }
  end
  local data = C_TooltipInfo.GetHyperlink(link)
  if not data then return { error = "geen tooltipdata" } end

  local lines = { hasDynamicData = data.hasDynamicData }
  for i, line in ipairs(data.lines or {}) do
    lines[i] = line.leftText
  end
  return lines
end

local function capture(unit, label)
  local entry = {
    label      = label,
    name       = UnitName(unit),
    guid       = UnitGUID(unit),
    capturedAt = time(),
    globalStr  = dumpGlobalString(),
    slots      = {},
  }

  for _, slot in ipairs(SLOTS) do
    local link = GetInventoryItemLink(unit, slot)
    if link then
      entry.slots[slot] = {
        link     = link,
        sockets  = socketSources(link),
        tooltip  = tooltipLines(link),
        setID    = select(16, C_Item.GetItemInfo(link)),
        ilvl     = C_Item.GetDetailedItemLevelInfo(link),
      }
    end
  end

  table.insert(RaidInspectorSpikeDB, entry)
  print(string.format("Spike: %s vastgelegd (%d slots).", label, #entry.slots))
end

SLASH_RISPIKE1 = "/rispike"
SlashCmdList["RISPIKE"] = function(msg)
  if msg == "wipe" then
    RaidInspectorSpikeDB = {}
    print("Spike: database geleegd.")
    return
  end
  if msg == "target" then
    if not UnitExists("target") then print("Spike: geen target."); return end
    NotifyInspect("target")
    print("Spike: inspect aangevraagd, wacht op INSPECT_READY.")
    return
  end
  capture("player", "player")
end

local f = CreateFrame("Frame")
f:RegisterEvent("INSPECT_READY")
f:SetScript("OnEvent", function(_, event, guid)
  local unit = UnitTokenFromGUID(guid)
  if unit and UnitGUID(unit) == guid then
    capture(unit, "inspect:" .. tostring(UnitName(unit)))
    ClearInspectPlayer()
  end
end)
```

- [ ] **Stap 3: Schrijf het deployscript**

Aanmaken `tools/deploy-spike.ps1`:

```powershell
$addons = "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns"
$source = Join-Path (Split-Path -Parent $PSScriptRoot) "spike\RaidInspectorSpike"
$target = Join-Path $addons "RaidInspectorSpike"

if (-not (Test-Path $addons)) { Write-Host "AddOns-map niet gevonden: $addons"; exit 1 }
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force
Write-Host "Spike gekopieerd naar $target"
Write-Host "Herstart WoW of typ /reload, en gebruik daarna /rispike"
```

Kopiëren en niet symlinken: een symlink naar `C:\Program Files (x86)` vereist verhoogde rechten.

- [ ] **Stap 4: Deploy en draai in-game**

```powershell
powershell -ExecutionPolicy Bypass -File tools\deploy-spike.ps1
```

Voer daarna in-game uit, in deze volgorde:

1. `/rispike` — legt je eigen uitrusting vast.
2. `/dump ITEM_UPGRADE_TOOLTIP_FORMAT_STRING` — beantwoordt open punt §14.2.
3. Target een raidlid en typ `/rispike target` — legt een echte inspect vast.
4. Herhaal stap 3 voor minstens vier spelers, waaronder iemand met crafted gear, iemand met een gesocket item, en iemand met een schild (open punt §14.1).
5. `/reload` om de SavedVariables weg te schrijven.

Het resultaat staat in:
`C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\RaidInspectorSpike.lua`

- [ ] **Stap 5: Leg de antwoorden vast**

Aanmaken `docs/superpowers/spike-resultaten.md` met, letterlijk overgenomen uit de SavedVariables:

- Minstens tien echte itemlinks, waaronder crafted, embellished, gesocket en tier
- Per gesocket item: wat `GetItemStats`, `GetItemNumSockets` en `GetItemNumAddedSockets` teruggaven
- De volledige tooltipregels van één geüpgraded item, inclusief de exacte upgrade-regel
- De waarde van `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING`
- Of `hasDynamicData` waar was bij de eerste uitlezing
- Of een schild een enchant-veld in de link draagt

- [ ] **Stap 6: Vervang de synthetische fixtures**

Vervang in `spec/fixtures/links.lua` de verzonnen links door de echte, en verwijder de waarschuwingscomment. Draai daarna:

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

Verwacht: alle tests slagen nog steeds. Falen ze, dan klopt de parser niet op echte data en is dat precies de bug die deze spike moest vinden — repareer de parser, niet de test.

- [ ] **Stap 7: Commit**

```powershell
git add spike tools/deploy-spike.ps1 docs/superpowers/spike-resultaten.md spec/fixtures/links.lua
git commit -m "feat: spike-addon en echte Midnight-fixtures"
```

---

### Taak 5: Evidence

**Bestanden:**
- Aanmaken: `RaidInspector/Evidence.lua`
- Aanmaken: `spec/Evidence_spec.lua`

**Interfaces:**
- Levert: `ns.Evidence.fingerprint(link)` geeft een getal terug dat identiek is onder Lua 5.1 en 5.4, of `nil` voor `nil`-invoer.
- Levert: `ns.Evidence.newSlotRecord()` geeft een verse `SlotRecord` met lege tellers.
- Levert: `ns.Evidence.record(slotRecord, link, evidence, now)` werkt de tellers bij en geeft de gewijzigde `slotRecord` terug. `evidence` is een tabel met booleans `linkComplete`, `socketsKnown`, `tooltipComplete`, `itemLoaded`. `now` is een tijdstempel in seconden.
- Levert: `ns.Evidence.isConfirmed(slotRecord, sources, minInterval)` geeft `true` als élke bron in de array `sources` minstens twee keer compleet gezien is bij de huidige fingerprint, met minstens `minInterval` seconden tussen de eerste en de laatste waarneming.

- [ ] **Stap 1: Schrijf de falende tests**

Aanmaken `spec/Evidence_spec.lua`:

```lua
local helper = dofile("spec/helper.lua")

local function evidence()
  return helper.loadModules({ "RaidInspector/Evidence.lua" }).Evidence
end

local COMPLETE = {
  linkComplete = true, socketsKnown = true,
  tooltipComplete = true, itemLoaded = true,
}
local NO_TOOLTIP = {
  linkComplete = true, socketsKnown = true,
  tooltipComplete = false, itemLoaded = true,
}

describe("Evidence fingerprint", function()
  it("geeft hetzelfde getal voor dezelfde string", function()
    local E = evidence()
    assert.equals(E.fingerprint("item:1:2:3"), E.fingerprint("item:1:2:3"))
  end)

  it("geeft verschillende getallen voor verschillende strings", function()
    local E = evidence()
    assert.truthy(E.fingerprint("item:1:2:3") ~= E.fingerprint("item:1:2:4"))
  end)

  it("blijft onder 2^32 zodat 5.1 en 5.4 hetzelfde rekenen", function()
    local E = evidence()
    local h = E.fingerprint(string.rep("x", 500))
    assert.truthy(h >= 0 and h < 4294967296)
  end)

  it("geeft nil voor nil", function()
    assert.is_nil(evidence().fingerprint(nil))
  end)
end)

describe("Evidence bevestiging", function()
  it("bevestigt niets na één uitlezing", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  it("bevestigt na twee complete uitlezingen ver genoeg uit elkaar", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  it("bevestigt niet als de twee uitlezingen te snel op elkaar volgen", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 103)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)

  -- Dit is het scenario dat het hele bewijsmodel rechtvaardigt: dezelfde link,
  -- twee keer gezien, maar de bron die de bevinding nodig heeft ontbrak beide
  -- keren. Zonder deze regel zou hier ten onrechte rood gekleurd worden.
  it("bevestigt een bron niet die twee keer ontbrak", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", NO_TOOLTIP, 100)
    E.record(rec, "item:1", NO_TOOLTIP, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
    assert.falsy(E.isConfirmed(rec, { "tooltipComplete" }, 10))
  end)

  it("eist dat elke gevraagde bron bevestigd is", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", NO_TOOLTIP, 100)
    E.record(rec, "item:1", NO_TOOLTIP, 115)
    assert.falsy(E.isConfirmed(rec, { "linkComplete", "tooltipComplete" }, 10))
  end)

  it("zet alle tellers terug als de fingerprint verandert", function()
    local E = evidence()
    local rec = E.newSlotRecord()
    E.record(rec, "item:1", COMPLETE, 100)
    E.record(rec, "item:1", COMPLETE, 115)
    assert.truthy(E.isConfirmed(rec, { "linkComplete" }, 10))
    E.record(rec, "item:2", COMPLETE, 130)
    assert.falsy(E.isConfirmed(rec, { "linkComplete" }, 10))
  end)
end)
```

- [ ] **Stap 2: Draai de tests en verifieer dat ze falen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Evidence"
```

Verwacht: tien failures met "kon niet laden: .../RaidInspector/Evidence.lua".

- [ ] **Stap 3: Schrijf de implementatie**

Aanmaken `RaidInspector/Evidence.lua`:

```lua
local addonName, ns = ...

local Evidence = {}
ns.Evidence = Evidence

Evidence.SOURCES = { "linkComplete", "socketsKnown", "tooltipComplete", "itemLoaded" }

-- djb2, expliciet begrensd op 2^32. De begrenzing is geen optimalisatie maar
-- een correctheidseis: WoW draait Lua 5.1 waar getallen doubles zijn met een
-- 53-bits mantisse, terwijl 5.3+ 64-bits integers gebruikt die overlopen. Door
-- onder 2^32 te blijven rekenen beide versies exact hetzelfde uit, en telt een
-- fingerprint die lokaal berekend is nog steeds in-game.
function Evidence.fingerprint(link)
  if type(link) ~= "string" then return nil end
  local h = 5381
  for i = 1, string.len(link) do
    h = (h * 33 + string.byte(link, i)) % 4294967296
  end
  return h
end

function Evidence.newSlotRecord()
  local reads = {}
  for i = 1, table.getn(Evidence.SOURCES) do
    reads[Evidence.SOURCES[i]] = { count = 0, firstAt = nil, lastAt = nil }
  end
  return { fingerprint = nil, reads = reads }
end

function Evidence.record(slotRecord, link, evidence, now)
  local fp = Evidence.fingerprint(link)

  if slotRecord.fingerprint ~= fp then
    slotRecord.fingerprint = fp
    for i = 1, table.getn(Evidence.SOURCES) do
      slotRecord.reads[Evidence.SOURCES[i]] = { count = 0, firstAt = nil, lastAt = nil }
    end
  end

  for i = 1, table.getn(Evidence.SOURCES) do
    local source = Evidence.SOURCES[i]
    if evidence and evidence[source] then
      local r = slotRecord.reads[source]
      r.count = r.count + 1
      r.firstAt = r.firstAt or now
      r.lastAt = now
    end
  end

  return slotRecord
end

function Evidence.isConfirmed(slotRecord, sources, minInterval)
  for i = 1, table.getn(sources) do
    local r = slotRecord.reads[sources[i]]
    if not r or r.count < 2 then return false end
    if not r.firstAt or not r.lastAt then return false end
    if (r.lastAt - r.firstAt) < minInterval then return false end
  end
  return true
end
```

- [ ] **Stap 4: Draai de tests en verifieer dat ze slagen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Evidence"
```

Verwacht: `10 geslaagd, 0 gefaald`.

- [ ] **Stap 5: Commit**

```powershell
git add RaidInspector/Evidence.lua spec/Evidence_spec.lua
git commit -m "feat: Evidence telt bewijs per bron in plaats van per itemlink"
```

---

### Taak 6: Policy

**Bestanden:**
- Aanmaken: `RaidInspector/Policy/Slots.lua`
- Aanmaken: `RaidInspector/Policy/Season.lua`
- Aanmaken: `spec/Policy_spec.lua`

**Interfaces:**
- Levert: `ns.Policy.Slots.ALL` — dichte array van de zestien slot-ID's die gecontroleerd worden.
- Levert: `ns.Policy.Slots.isEnchantable(slot, itemSubclass)` — `true` voor enchantbare slots; voor de off-hand alleen als `itemSubclass` op een wapen wijst.
- Levert: `ns.Policy.Slots.isSocketable(slot)` — `true` voor helm, bracers en riem.
- Levert: `ns.Policy.Slots.TIER` — array van de vijf tier-slots.
- Levert: `ns.Policy.Season.CURRENT_TIER` — string die de actuele enchant- en gemtier aanduidt.
- Levert: `ns.Policy.Season.TIER_SET_IDS` — map van setID naar `true` voor de actuele tierset.
- Levert: `ns.Policy.Season.MAX_EMBELLISHMENTS` — getal, 2.

- [ ] **Stap 1: Schrijf de falende tests**

Aanmaken `spec/Policy_spec.lua`:

```lua
local helper = dofile("spec/helper.lua")

local function policy()
  return helper.loadModules({
    "RaidInspector/Policy/Slots.lua",
    "RaidInspector/Policy/Season.lua",
  }).Policy
end

describe("Policy slots", function()
  it("controleert precies zestien slots", function()
    assert.equals(16, table.getn(policy().Slots.ALL))
  end)

  it("markeert helm, shoulders, chest, benen, boots en ringen als enchantbaar", function()
    local S = policy().Slots
    assert.truthy(S.isEnchantable(1))
    assert.truthy(S.isEnchantable(3))
    assert.truthy(S.isEnchantable(5))
    assert.truthy(S.isEnchantable(7))
    assert.truthy(S.isEnchantable(8))
    assert.truthy(S.isEnchantable(11))
    assert.truthy(S.isEnchantable(12))
  end)

  it("markeert cloak en bracers niet als enchantbaar in Midnight", function()
    local S = policy().Slots
    assert.falsy(S.isEnchantable(15))
    assert.falsy(S.isEnchantable(9))
  end)

  it("eist een enchant op een off-hand wapen maar niet op een schild", function()
    local S = policy().Slots
    assert.truthy(S.isEnchantable(17, "weapon"))
    assert.falsy(S.isEnchantable(17, "shield"))
    assert.falsy(S.isEnchantable(17, "holdable"))
  end)

  it("markeert helm, bracers en riem als socket-baar", function()
    local S = policy().Slots
    assert.truthy(S.isSocketable(1))
    assert.truthy(S.isSocketable(9))
    assert.truthy(S.isSocketable(6))
    assert.falsy(S.isSocketable(5))
  end)

  it("kent vijf tier-slots", function()
    assert.equals(5, table.getn(policy().Slots.TIER))
  end)
end)

describe("Policy seizoen", function()
  it("noemt de actuele tier", function()
    assert.equals("midnight-s1", policy().Season.CURRENT_TIER)
  end)

  it("staat maximaal twee embellishments toe", function()
    assert.equals(2, policy().Season.MAX_EMBELLISHMENTS)
  end)

  it("houdt de tier-setIDs op één plek", function()
    assert.equals("table", type(policy().Season.TIER_SET_IDS))
  end)
end)
```

- [ ] **Stap 2: Draai de tests en verifieer dat ze falen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Policy"
```

Verwacht: negen failures met laadfouten.

- [ ] **Stap 3: Schrijf de slot-policy**

Aanmaken `RaidInspector/Policy/Slots.lua`:

```lua
local addonName, ns = ...

ns.Policy = ns.Policy or {}
local Slots = {}
ns.Policy.Slots = Slots

-- WoW inventarisslot-nummers. Bewust letterlijk en niet via INVSLOT_-globals,
-- zodat dit bestand buiten de game te laden en te testen is.
local HEAD, NECK, SHOULDER, SHIRT = 1, 2, 3, 4
local CHEST, WAIST, LEGS, FEET    = 5, 6, 7, 8
local WRIST, HANDS, FINGER1       = 9, 10, 11
local FINGER2, TRINKET1, TRINKET2 = 12, 13, 14
local BACK, MAINHAND, OFFHAND     = 15, 16, 17

Slots.ALL = {
  HEAD, NECK, SHOULDER, BACK, CHEST, WRIST, HANDS, WAIST,
  LEGS, FEET, FINGER1, FINGER2, TRINKET1, TRINKET2, MAINHAND, OFFHAND,
}

Slots.TIER = { HEAD, SHOULDER, CHEST, HANDS, LEGS }

-- Midnight seizoen 1: cloak en bracers zijn eruit, helm en shoulders terug.
-- Benen dragen een spellthread, die in hetzelfde enchantID-veld terechtkomt.
local ENCHANTABLE = {
  [HEAD] = true, [SHOULDER] = true, [CHEST] = true, [LEGS] = true,
  [FEET] = true, [FINGER1] = true, [FINGER2] = true, [MAINHAND] = true,
}

-- Items die een socket kunnen krijgen via een los te kopen item.
local SOCKETABLE = { [HEAD] = true, [WRIST] = true, [WAIST] = true }

function Slots.isEnchantable(slot, itemSubclass)
  if slot == OFFHAND then
    return itemSubclass == "weapon"
  end
  return ENCHANTABLE[slot] == true
end

function Slots.isSocketable(slot)
  return SOCKETABLE[slot] == true
end
```

- [ ] **Stap 4: Schrijf de seizoens-policy**

Aanmaken `RaidInspector/Policy/Season.lua`:

```lua
local addonName, ns = ...

ns.Policy = ns.Policy or {}
local Season = {}
ns.Policy.Season = Season

-- Welke tier als "actueel" telt. Data/Enchants.lua en Data/Gems.lua bevatten de
-- volledige historie met een tier-tag; dit bestand bepaalt wat daarvan actueel
-- is. Zo levert een bekende maar verouderde ID een waarschuwing op in plaats
-- van "onbekend", en blijft onbekend gereserveerd voor wat echt niet herkend is.
Season.CURRENT_TIER = "midnight-s1"

Season.MAX_EMBELLISHMENTS = 2

-- Enige plek waar de actuele tier-setIDs staan. Bewust niet ook in Data/,
-- want twee bronnen voor hetzelfde feit lopen gegarandeerd uiteen.
-- Vul in met de setID's uit de spike; de placeholder maakt de tier-check
-- inactief zonder foute meldingen te produceren.
Season.TIER_SET_IDS = {}
```

- [ ] **Stap 5: Draai de tests en verifieer dat ze slagen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Policy"
```

Verwacht: `9 geslaagd, 0 gefaald`.

- [ ] **Stap 6: Commit**

```powershell
git add RaidInspector/Policy spec/Policy_spec.lua
git commit -m "feat: Policy scheidt slotregels van seizoensoordeel"
```

---

### Taak 7: Rules — enchants en gems

**Bestanden:**
- Aanmaken: `RaidInspector/Rules.lua`
- Aanmaken: `spec/Rules_spec.lua`
- Aanmaken: `RaidInspector/Data/Enchants.lua`
- Aanmaken: `RaidInspector/Data/Gems.lua`

**Interfaces:**
- Verbruikt: `ns.Policy.Slots`, `ns.Policy.Season`, `ns.Evidence`.
- Levert: `ns.Rules.evaluateSlot(slot, parsed, slotRecord, context)` geeft een dichte array van bevindingen terug. `parsed` is de uitvoer van `LinkParser.parse` of `nil` voor een leeg slot. `context` is een tabel met `minInterval` (getal), `dataValid` (boolean) en `itemSubclass` (string of `nil`).
- Elke bevinding is `{ slot = <getal>, kind = <string>, severity = "error"|"warn", state = "bad"|"unknown", detail = <string> }`.

- [ ] **Stap 1: Schrijf gestubde datatabellen**

Aanmaken `RaidInspector/Data/Enchants.lua`:

```lua
local addonName, ns = ...

ns.Data = ns.Data or {}

-- GEGENEREERD in deel 2 uit wago.tools. Deze stub bevat alleen genoeg entries
-- om de regels te kunnen testen. Vorm: enchantID -> { quality, tier }.
-- quality is "silver" of "gold"; tier is de seizoenstag.
ns.Data.Enchants = {
  [7364] = { quality = "gold",   tier = "midnight-s1" },
  [7361] = { quality = "silver", tier = "midnight-s1" },
  [6625] = { quality = "gold",   tier = "tww-s4" },
}
```

Aanmaken `RaidInspector/Data/Gems.lua`:

```lua
local addonName, ns = ...

ns.Data = ns.Data or {}

-- GEGENEREERD in deel 2. Vorm: gemID -> { quality, tier }.
ns.Data.Gems = {
  [213743] = { quality = "gold",   tier = "midnight-s1" },
  [213740] = { quality = "silver", tier = "midnight-s1" },
  [213470] = { quality = "gold",   tier = "tww-s4" },
}
```

- [ ] **Stap 2: Schrijf de falende tests**

Aanmaken `spec/Rules_spec.lua`:

```lua
local helper = dofile("spec/helper.lua")

local MODULES = {
  "RaidInspector/Policy/Slots.lua",
  "RaidInspector/Policy/Season.lua",
  "RaidInspector/Data/Enchants.lua",
  "RaidInspector/Data/Gems.lua",
  "RaidInspector/Evidence.lua",
  "RaidInspector/Rules.lua",
}

local function fresh()
  return helper.loadModules(MODULES)
end

local COMPLETE = {
  linkComplete = true, socketsKnown = true,
  tooltipComplete = true, itemLoaded = true,
}

-- Bouwt een slotRecord dat twee complete uitlezingen ver genoeg uit elkaar
-- heeft, zodat negatieve bevindingen bevestigd mogen worden.
local function confirmedRecord(ns, link)
  local rec = ns.Evidence.newSlotRecord()
  ns.Evidence.record(rec, link, COMPLETE, 100)
  ns.Evidence.record(rec, link, COMPLETE, 120)
  return rec
end

local function findingOfKind(findings, kind)
  for i = 1, table.getn(findings) do
    if findings[i].kind == kind then return findings[i] end
  end
  return nil
end

local CONTEXT = { minInterval = 10, dataValid = true }

describe("Rules enchants", function()
  it("meldt niets als er een actuele gold-enchant op zit", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7364, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)

  it("meldt een ontbrekende enchant op een enchantbaar slot", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 0, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT),
      "missing_enchant")
    assert.equals("error", f.severity)
    assert.equals("bad", f.state)
  end)

  it("meldt geen ontbrekende enchant op een niet-enchantbaar slot", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 0, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(15, parsed, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "missing_enchant"))
  end)

  it("markeert een ontbrekende enchant als onbekend zonder bevestiging", function()
    local ns = fresh()
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, "a", COMPLETE, 100)
    local parsed = { itemID = 1, enchantID = 0, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(ns.Rules.evaluateSlot(1, parsed, rec, CONTEXT), "missing_enchant")
    assert.equals("unknown", f.state)
  end)

  it("meldt een silver-enchant als waarschuwing", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7361, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT), "low_enchant")
    assert.equals("warn", f.severity)
  end)

  it("meldt een enchant uit een vorig seizoen als verouderd, niet als onbekend", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 6625, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT)
    local f = findingOfKind(findings, "outdated_enchant")
    assert.equals("warn", f.severity)
    assert.equals("bad", f.state)
  end)

  it("markeert een onbekende enchant-ID als onbekend", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 999999, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT)
    assert.is_nil(findingOfKind(findings, "outdated_enchant"))
    assert.is_nil(findingOfKind(findings, "low_enchant"))
  end)

  it("degradeert alles naar onbekend als de data ongeldig is", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7361, gemIDs = {0,0,0,0}, gemCount = 0,
                     bonusIDs = {}, modifiers = {} }
    local findings = ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"),
                                           { minInterval = 10, dataValid = false })
    local f = findingOfKind(findings, "low_enchant")
    assert.is_nil(f)
  end)
end)

describe("Rules gems", function()
  it("meldt een silver-gem als waarschuwing", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7364, gemIDs = {213740,0,0,0}, gemCount = 1,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT), "low_gem")
    assert.equals("warn", f.severity)
  end)

  it("meldt een gem uit een vorig seizoen als verouderd", function()
    local ns = fresh()
    local parsed = { itemID = 1, enchantID = 7364, gemIDs = {213470,0,0,0}, gemCount = 1,
                     bonusIDs = {}, modifiers = {} }
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, parsed, confirmedRecord(ns, "a"), CONTEXT), "outdated_gem")
    assert.equals("warn", f.severity)
  end)
end)

describe("Rules leeg slot", function()
  it("meldt een leeg gear-slot als fout", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluateSlot(1, nil, confirmedRecord(ns, "a"), CONTEXT), "missing_item")
    assert.equals("error", f.severity)
  end)

  it("meldt een lege off-hand niet als er een tweehander is", function()
    local ns = fresh()
    local ctx = { minInterval = 10, dataValid = true, twoHanded = true }
    local findings = ns.Rules.evaluateSlot(17, nil, confirmedRecord(ns, "a"), ctx)
    assert.is_nil(findingOfKind(findings, "missing_item"))
  end)
end)
```

- [ ] **Stap 3: Draai de tests en verifieer dat ze falen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Rules"
```

Verwacht: twaalf failures met "kon niet laden: .../RaidInspector/Rules.lua".

- [ ] **Stap 4: Schrijf de implementatie**

Aanmaken `RaidInspector/Rules.lua`:

```lua
local addonName, ns = ...

local Rules = {}
ns.Rules = Rules

local function add(findings, slot, kind, severity, state, detail)
  findings[table.getn(findings) + 1] = {
    slot = slot, kind = kind, severity = severity,
    state = state, detail = detail,
  }
end

-- Negatieve bevindingen mogen pas "bad" worden als het bewijs er is; tot die
-- tijd zijn ze "unknown". Dit is de kern van sectie 6 van de spec: een rood
-- vakje op grond van data die nog niet binnen was, is erger dan geen data.
local function stateFor(slotRecord, sources, context)
  if ns.Evidence.isConfirmed(slotRecord, sources, context.minInterval) then
    return "bad"
  end
  return "unknown"
end

local function checkEnchant(findings, slot, parsed, slotRecord, context)
  if not ns.Policy.Slots.isEnchantable(slot, context.itemSubclass) then return end

  if parsed.enchantID == 0 then
    add(findings, slot, "missing_enchant", "error",
        stateFor(slotRecord, { "linkComplete" }, context),
        "geen enchant op een enchantbaar slot")
    return
  end

  if not context.dataValid then return end

  local info = ns.Data.Enchants[parsed.enchantID]
  if not info then return end

  if info.tier ~= ns.Policy.Season.CURRENT_TIER then
    add(findings, slot, "outdated_enchant", "warn",
        stateFor(slotRecord, { "linkComplete" }, context),
        "enchant uit " .. info.tier)
  elseif info.quality ~= "gold" then
    add(findings, slot, "low_enchant", "warn",
        stateFor(slotRecord, { "linkComplete" }, context),
        "enchant is " .. info.quality .. " in plaats van gold")
  end
end

local function checkGems(findings, slot, parsed, slotRecord, context)
  if not context.dataValid then return end

  for i = 1, 4 do
    local gemID = parsed.gemIDs[i]
    if gemID ~= 0 then
      local info = ns.Data.Gems[gemID]
      if info then
        if info.tier ~= ns.Policy.Season.CURRENT_TIER then
          add(findings, slot, "outdated_gem", "warn",
              stateFor(slotRecord, { "linkComplete" }, context),
              "gem uit " .. info.tier)
        elseif info.quality ~= "gold" then
          add(findings, slot, "low_gem", "warn",
              stateFor(slotRecord, { "linkComplete" }, context),
              "gem is " .. info.quality .. " in plaats van gold")
        end
      end
    end
  end
end

function Rules.evaluateSlot(slot, parsed, slotRecord, context)
  local findings = {}

  if not parsed then
    local isEmptyOffhandWithTwoHander = (slot == 17 and context.twoHanded)
    if not isEmptyOffhandWithTwoHander then
      add(findings, slot, "missing_item", "error",
          stateFor(slotRecord, { "itemLoaded" }, context),
          "geen item in dit slot")
    end
    return findings
  end

  checkEnchant(findings, slot, parsed, slotRecord, context)
  checkGems(findings, slot, parsed, slotRecord, context)

  return findings
end
```

- [ ] **Stap 5: Draai de tests en verifieer dat ze slagen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "Rules"
```

Verwacht: `12 geslaagd, 0 gefaald`.

- [ ] **Stap 6: Commit**

```powershell
git add RaidInspector/Rules.lua RaidInspector/Data spec/Rules_spec.lua
git commit -m "feat: Rules controleert enchants en gems met bewijsgestuurde toestand"
```

---

### Taak 8: Rules — tier en embellishments

**Bestanden:**
- Wijzigen: `RaidInspector/Rules.lua`
- Wijzigen: `spec/Rules_spec.lua`
- Aanmaken: `RaidInspector/Data/Embellishments.lua`

**Interfaces:**
- Levert: `ns.Rules.evaluatePlayer(slots, context)` waarbij `slots` een map is van slot-ID naar `{ parsed = <tabel of nil>, record = <slotRecord>, setID = <getal of nil> }`. Geeft een dichte array bevindingen terug voor de speler als geheel, dus inclusief `tier_incomplete` en `embellishments_missing` die over meerdere slots gaan.

Tier en embellishments zijn de eerste checks die niet per slot te beoordelen zijn: je kunt pas zeggen dat iemand 3 van 5 tierstukken draagt als je alle vijf slots gezien hebt.

- [ ] **Stap 1: Schrijf de stub voor embellishments**

Aanmaken `RaidInspector/Data/Embellishments.lua`:

```lua
local addonName, ns = ...

ns.Data = ns.Data or {}

-- GEGENEREERD in deel 2 uit wago.tools. Vorm: bonusID -> { name }.
ns.Data.Embellishments = {
  [11144] = { name = "Testembellishment A" },
  [11145] = { name = "Testembellishment B" },
}
```

Voeg het bestand meteen toe aan de modulelijst boven in `spec/Rules_spec.lua`, anders is
`ns.Data.Embellishments` nil en faalt alleen de test mét embellishments, met een verwarrende
nil-index fout in plaats van een duidelijke assertie:

```lua
local MODULES = {
  "RaidInspector/Policy/Slots.lua",
  "RaidInspector/Policy/Season.lua",
  "RaidInspector/Data/Enchants.lua",
  "RaidInspector/Data/Gems.lua",
  "RaidInspector/Data/Embellishments.lua",
  "RaidInspector/Evidence.lua",
  "RaidInspector/Rules.lua",
}
```

- [ ] **Stap 2: Schrijf de falende tests**

Toevoegen aan `spec/Rules_spec.lua`, aan het eind:

```lua
describe("Rules speler-brede checks", function()
  local function slotEntry(ns, opts)
    local rec = ns.Evidence.newSlotRecord()
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 100)
    ns.Evidence.record(rec, opts.link or "a", COMPLETE, 120)
    return {
      parsed = opts.parsed or { itemID = 1, enchantID = 7364, gemIDs = {0,0,0,0},
                                gemCount = 0, bonusIDs = opts.bonusIDs or {}, modifiers = {} },
      record = rec,
      setID  = opts.setID,
    }
  end

  local function withTierSet(ns, count)
    ns.Policy.Season.TIER_SET_IDS = { [4242] = true }
    local slots = {}
    local tierSlots = ns.Policy.Slots.TIER
    for i = 1, table.getn(tierSlots) do
      slots[tierSlots[i]] = slotEntry(ns, { setID = (i <= count) and 4242 or nil,
                                            link = "tier" .. i })
    end
    return slots
  end

  it("meldt niets bij vijf van de vijf tierstukken", function()
    local ns = fresh()
    local findings = ns.Rules.evaluatePlayer(withTierSet(ns, 5), CONTEXT)
    assert.is_nil(findingOfKind(findings, "tier_incomplete"))
  end)

  it("meldt drie van de vijf tierstukken als waarschuwing", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluatePlayer(withTierSet(ns, 3), CONTEXT), "tier_incomplete")
    assert.equals("warn", f.severity)
    assert.matches("3", f.detail)
  end)

  it("meldt tier niet als de setIDs nog niet ingevuld zijn", function()
    local ns = fresh()
    ns.Policy.Season.TIER_SET_IDS = {}
    local slots = {}
    local tierSlots = ns.Policy.Slots.TIER
    for i = 1, table.getn(tierSlots) do
      slots[tierSlots[i]] = slotEntry(ns, { link = "x" .. i })
    end
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "tier_incomplete"))
  end)

  it("meldt nul embellishments als waarschuwing", function()
    local ns = fresh()
    local f = findingOfKind(
      ns.Rules.evaluatePlayer({ [5] = slotEntry(ns, {}) }, CONTEXT),
      "embellishments_missing")
    assert.equals("warn", f.severity)
  end)

  it("meldt niets bij twee embellishments", function()
    local ns = fresh()
    local slots = {
      [5]  = slotEntry(ns, { bonusIDs = { 11144 }, link = "c1" }),
      [10] = slotEntry(ns, { bonusIDs = { 11145 }, link = "c2" }),
    }
    assert.is_nil(findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT),
                                "embellishments_missing"))
  end)

  it("meldt geen embellishments als de data ongeldig is", function()
    local ns = fresh()
    local findings = ns.Rules.evaluatePlayer({ [5] = slotEntry(ns, {}) },
                                             { minInterval = 10, dataValid = false })
    assert.is_nil(findingOfKind(findings, "embellishments_missing"))
  end)

  it("bundelt de bevindingen per slot in het spelerresultaat", function()
    local ns = fresh()
    local slots = {
      [1] = slotEntry(ns, { parsed = { itemID = 1, enchantID = 0, gemIDs = {0,0,0,0},
                                       gemCount = 0, bonusIDs = {}, modifiers = {} } }),
    }
    local f = findingOfKind(ns.Rules.evaluatePlayer(slots, CONTEXT), "missing_enchant")
    assert.equals(1, f.slot)
  end)
end)
```

- [ ] **Stap 3: Draai de tests en verifieer dat ze falen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1 -Filter "speler-brede"
```

Verwacht: zeven failures met "attempt to call field 'evaluatePlayer' (a nil value)".

- [ ] **Stap 4: Breid de implementatie uit**

Toevoegen aan `RaidInspector/Rules.lua`, vóór de afsluitende regel:

```lua
local function countTierPieces(slots)
  local setIDs = ns.Policy.Season.TIER_SET_IDS
  local known = false
  for _ in pairs(setIDs) do known = true; break end
  if not known then return nil end

  local tierSlots = ns.Policy.Slots.TIER
  local worn = 0
  for i = 1, table.getn(tierSlots) do
    local entry = slots[tierSlots[i]]
    if entry and entry.setID and setIDs[entry.setID] then
      worn = worn + 1
    end
  end
  return worn, table.getn(tierSlots)
end

local function countEmbellishments(slots)
  local found = 0
  for _, entry in pairs(slots) do
    if entry.parsed and entry.parsed.bonusIDs then
      for i = 1, table.getn(entry.parsed.bonusIDs) do
        if ns.Data.Embellishments[entry.parsed.bonusIDs[i]] then
          found = found + 1
        end
      end
    end
  end
  return found
end

function Rules.evaluatePlayer(slots, context)
  local findings = {}

  for slot, entry in pairs(slots) do
    local slotFindings = Rules.evaluateSlot(slot, entry.parsed, entry.record, context)
    for i = 1, table.getn(slotFindings) do
      findings[table.getn(findings) + 1] = slotFindings[i]
    end
  end

  if not context.dataValid then return findings end

  local worn, total = countTierPieces(slots)
  if worn and worn < total then
    add(findings, nil, "tier_incomplete", "warn", "bad",
        worn .. " van " .. total .. " tierstukken")
  end

  local embellishments = countEmbellishments(slots)
  local maxEmbellishments = ns.Policy.Season.MAX_EMBELLISHMENTS
  if embellishments < maxEmbellishments then
    add(findings, nil, "embellishments_missing", "warn", "bad",
        embellishments .. " van " .. maxEmbellishments .. " embellishments")
  end

  return findings
end
```

- [ ] **Stap 5: Draai alle tests en verifieer dat ze slagen**

```powershell
powershell -ExecutionPolicy Bypass -File tools\test.ps1
```

Verwacht: `56 geslaagd, 0 gefaald` — vier uit het harnas, veertien uit LinkParser, tien uit Evidence, negen uit Policy en negentien uit Rules.

- [ ] **Stap 6: Commit**

```powershell
git add RaidInspector/Rules.lua RaidInspector/Data/Embellishments.lua spec/Rules_spec.lua
git commit -m "feat: Rules controleert tier en embellishments over slots heen"
```

---

## Wat er na dit plan nog moet gebeuren

Deel 2 wordt geschreven zodra de spike-resultaten uit taak 4 er zijn, en dekt:

- `Scanner` — drie wachtrijen met budgetaandeel, backoff, contentie met Blizzards inspectvenster, `unreachable`-uitgang via `UNIT_IN_RANGE_UPDATE`
- `Hydrator` — asynchrone itemcache met faalpad en timeout
- `UpgradeTrackAdapter` — tooltipparsing met `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING`
- `Rules` uitbreiden met `empty_socket`, `missing_socket` en `upgrades_left`
- `Cache` — SavedVariables met schemaversie, TTL en opruiming
- `UI/Grid` en `UI/Detail`
- `tools/generate.mjs` — wago.tools CSV naar `Data/*.lua`, met patchversie-gebonden degradatie

De reden voor die knip staat in §15 van de spec: `Rules` schrijven tegen een aangenomen recordvorm terwijl de invoer van de `Hydrator` het onzekerst is, is de enige echte afhankelijkheidsval in dit ontwerp.
