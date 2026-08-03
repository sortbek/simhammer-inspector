-- Loads addon modules exactly the way WoW does: every file is a chunk that
-- receives two arguments, the addon name and a shared namespace table. Using
-- the same shape means a module that quietly reaches for a WoW global cannot
-- slip through unnoticed here.

local helper = {}

local function repoRoot()
  local dir = string.match(debug.getinfo(1, "S").source, "^@(.*)[/\\]spec[/\\]helper%.lua$")
  return dir or "."
end

function helper.loadModules(paths)
  local ns = {}
  for i = 1, table.getn(paths) do
    local full = repoRoot() .. "/" .. paths[i]
    local chunk = assert(loadfile(full), "could not load: " .. full)
    chunk("RaidInspector", ns)
  end
  return ns
end

return helper
