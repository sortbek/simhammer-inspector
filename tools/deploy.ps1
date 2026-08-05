$root   = Split-Path -Parent $PSScriptRoot
$toc    = Join-Path $root "SimhammerInspector.toc"
$addons = "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns"
$target = Join-Path $addons "SimhammerInspector"

if (-not (Test-Path $addons)) { Write-Host "AddOns folder not found: $addons"; exit 1 }

# The addon now shares the repo root with spec, tools, spike and docs, so a
# recursive copy would ship the entire checkout into the AddOns folder. The TOC
# already lists every file the addon loads, which makes it the one list worth
# copying -- and unlike an exclude list it cannot quietly miss whatever folder
# gets added next. A file missing from the TOC would not load in game either.
$files = Get-Content $toc |
         Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne "" } |
         ForEach-Object { $_.Trim() }

# Copy rather than symlink: a symlink into C:\Program Files (x86) needs elevated
# privileges.
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path $toc -Destination $target -Force

foreach ($file in $files) {
  $source = Join-Path $root $file
  if (-not (Test-Path $source)) { Write-Host "TOC lists a file that is missing: $file"; exit 1 }

  $destination = Join-Path $target $file
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -Path $source -Destination $destination -Force
}

Write-Host "SimhammerInspector copied to $target ($($files.Count) files)"
Write-Host "Restart WoW or type /reload, then use /sh, /sh scan or /sh debug"
