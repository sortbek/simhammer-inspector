local helper = dofile("spec/helper.lua")

local function dv()
  return helper.loadModules({ "SimhammerInspector/DataVersion.lua" }).DataVersion
end

describe("DataVersion comparison", function()
  it("calls equal versions current", function()
    assert.equals("current", dv().compare({ version = "12.0.7", build = "68887" },
                                          { version = "12.0.7", build = "68887" }))
  end)

  it("treats a newer build within the same patch as no problem", function()
    assert.equals("newer-build", dv().compare({ version = "12.0.7", build = "68887" },
                                              { version = "12.0.7", build = "69120" }))
  end)

  it("treats a newer patch version as a problem", function()
    assert.equals("newer-patch", dv().compare({ version = "12.0.7", build = "68887" },
                                              { version = "12.1.0", build = "69000" }))
  end)

  it("recognises a newer major version too", function()
    assert.equals("newer-patch", dv().compare({ version = "12.0.7", build = "68887" },
                                              { version = "13.0.0", build = "70000" }))
  end)

  it("calls an older game version current", function()
    assert.equals("current", dv().compare({ version = "12.0.7", build = "68887" },
                                          { version = "12.0.5", build = "68000" }))
  end)

  it("returns newer-patch for unparseable versions, because silence is safer", function()
    assert.equals("newer-patch", dv().compare({ version = nil }, { version = "12.0.7" }))
  end)
end)

describe("DataVersion validity", function()
  it("allows current data", function()
    assert.truthy(dv().isValid("current"))
  end)

  it("allows a newer build", function()
    assert.truthy(dv().isValid("newer-build"))
  end)

  it("blocks on a newer patch", function()
    assert.falsy(dv().isValid("newer-patch"))
  end)
end)
