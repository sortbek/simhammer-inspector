local helper = dofile("spec/helper.lua")

local MODULES = {
  "Policy/Slots.lua",
  "Evidence.lua",
  "Scanner.lua",
}

-- Scanner touches no WoW API while loading, so it can be brought up here as long
-- as the handful of globals it calls are staged first. They are restored
-- afterwards: every spec file shares one Lua state, and a leftover
-- InCombatLockdown would follow the whole suite around.
local WOW_GLOBALS = { "InCombatLockdown", "IsEncounterInProgress", "CreateFrame", "C_Timer" }

local function stubFrame()
  local f = {}
  function f:RegisterEvent() end
  function f:SetScript() end
  return f
end

-- rawset, because the runner makes creating a global an error on purpose. That
-- guard is for production code accidentally leaking a name into the client's
-- shared namespace; here the globals are the thing under test, staged and put
-- back within the call.
local function withWorld(world, fn)
  local saved = {}
  for i = 1, table.getn(WOW_GLOBALS) do saved[i] = _G[WOW_GLOBALS[i]] end

  rawset(_G, "InCombatLockdown", world.inCombat)
  rawset(_G, "IsEncounterInProgress", world.inEncounter)
  rawset(_G, "CreateFrame", stubFrame)
  rawset(_G, "C_Timer", { NewTicker = function() end, After = function() end })

  local ok, err = pcall(fn, helper.loadModules(MODULES).Scanner)

  for i = 1, table.getn(WOW_GLOBALS) do rawset(_G, WOW_GLOBALS[i], saved[i]) end
  if not ok then error(err, 0) end
end

local function yes() return true end
local function no() return false end

describe("Scanner combat state", function()
  it("is out of combat when nothing says otherwise", function()
    withWorld({ inCombat = no, inEncounter = no }, function(Scanner)
      assert.equals(false, Scanner.inCombat())
    end)
  end)

  it("reads combat off the client rather than an event it was not there for", function()
    withWorld({ inCombat = yes, inEncounter = no }, function(Scanner)
      assert.equals(true, Scanner.inCombat())
    end)
  end)

  -- Someone who reloads while dead is not personally in combat, but the pull is
  -- still running, and inspecting through a pull is the thing being avoided.
  it("counts a running encounter as combat", function()
    withWorld({ inCombat = no, inEncounter = yes }, function(Scanner)
      assert.equals(true, Scanner.inCombat())
    end)
  end)

  it("survives a client that offers neither call", function()
    withWorld({}, function(Scanner)
      assert.equals(false, Scanner.inCombat())
    end)
  end)
end)

-- The bug this covers: PLAYER_REGEN_DISABLED fires when combat starts, which for
-- a mid-pull /reload is before this addon exists. Starting from `false` meant
-- coming back believing the raid was idle and inspecting through the encounter
-- the pause was written to stay out of.
describe("Scanner startup", function()
  it("comes back paused when the reload happened mid-pull", function()
    withWorld({ inCombat = yes, inEncounter = no }, function(Scanner)
      Scanner.init({}, {}, {})
      assert.equals(true, Scanner.isPaused())
    end)
  end)

  it("comes back scanning when the reload happened out of combat", function()
    withWorld({ inCombat = no, inEncounter = no }, function(Scanner)
      Scanner.init({}, {}, {})
      assert.falsy(Scanner.isPaused())
    end)
  end)
end)
