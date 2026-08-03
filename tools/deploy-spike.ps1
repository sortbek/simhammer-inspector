$addons = "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns"
$source = Join-Path (Split-Path -Parent $PSScriptRoot) "spike\RaidInspectorSpike"
$target = Join-Path $addons "RaidInspectorSpike"

if (-not (Test-Path $addons)) { Write-Host "AddOns-map niet gevonden: $addons"; exit 1 }

# Kopieren en niet symlinken: een symlink naar C:\Program Files (x86) vereist
# verhoogde rechten.
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force

Write-Host "Spike gekopieerd naar $target"
Write-Host "Herstart WoW of typ /reload, en gebruik daarna /rispike"
