local helper = dofile("spec/helper.lua")

local function versionModule()
  return helper.loadModules({ "Version.lua" })
end

describe("addon version", function()
  it("reports the number the packager wrote into the TOC", function()
    assert.equals("1.2.0", versionModule().readVersion("1.2.0"))
  end)

  -- A working copy has never been through the packager, so its TOC still holds
  -- the substitution token verbatim. Printing that in the login line is how you
  -- greet yourself with "loaded @project-version@" every time you reload.
  it("calls an unsubstituted token a dev build", function()
    assert.equals("dev", versionModule().readVersion("@project-version@"))
  end)

  it("calls a missing version a dev build", function()
    assert.equals("dev", versionModule().readVersion(nil))
    assert.equals("dev", versionModule().readVersion(""))
  end)

  -- Outside the game there is no TOC and no API to read it with, which is the
  -- same situation as a working copy and gets the same answer.
  it("comes out as a dev build with no client to ask", function()
    assert.equals("dev", versionModule().VERSION)
  end)
end)
