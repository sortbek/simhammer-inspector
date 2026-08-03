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
