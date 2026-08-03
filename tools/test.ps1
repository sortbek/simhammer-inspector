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
