$addons = "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns"
$source = Join-Path (Split-Path -Parent $PSScriptRoot) "SimhammerInspector"
$target = Join-Path $addons "SimhammerInspector"

if (-not (Test-Path $addons)) { Write-Host "AddOns folder not found: $addons"; exit 1 }

# Copy rather than symlink: a symlink into C:\Program Files (x86) needs elevated
# privileges.
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force

Write-Host "SimhammerInspector copied to $target"
Write-Host "Restart WoW or type /reload, then use /sh, /sh scan or /sh debug"
