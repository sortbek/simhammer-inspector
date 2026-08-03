param([string]$Filter = "")

$root    = Split-Path -Parent $PSScriptRoot
$lua     = Join-Path $PSScriptRoot "lua\lua5.1.exe"
$runner  = Join-Path $PSScriptRoot "run-tests.lua"
$specDir = Join-Path $root "spec"

$specs = Get-ChildItem -Path $specDir -Filter "*_spec.lua" -Recurse |
         ForEach-Object { $_.FullName }

if (-not $specs) { Write-Host "No spec files found in $specDir"; exit 1 }

$luaArgs = @($runner)
if ($Filter -ne "") { $luaArgs += "--filter=$Filter" }
$luaArgs += $specs

# The working directory must be the repo root: spec files do
# dofile("spec/helper.lua") with a relative path, and that has to work no matter
# where the script is invoked from.
Push-Location $root
try { & $lua $luaArgs; $code = $LASTEXITCODE } finally { Pop-Location }
exit $code
