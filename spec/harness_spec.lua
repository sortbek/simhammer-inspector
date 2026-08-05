describe("test harness", function()
  it("runs under Lua 5.1", function()
    assert.equals("Lua 5.1", _VERSION)
  end)

  it("has unpack as a global and no table.unpack", function()
    assert.equals("function", type(unpack))
    assert.is_nil(table.unpack)
  end)

  it("compares nested tables and names the diverging path", function()
    local ok, err = pcall(function()
      assert.same({ a = { b = 1 } }, { a = { b = 2 } })
    end)
    assert.falsy(ok)
    assert.matches("%.a%.b", err)
  end)

  -- Asserts that the chunk ran and wrote into the shared namespace, not what it
  -- wrote: the version number comes from the git tag now, so pinning a literal
  -- here would fail on every release for reasons that have nothing to do with
  -- the harness.
  it("loads a module with the addon namespace", function()
    local helper = dofile("spec/helper.lua")
    local ns = helper.loadModules({ "SimhammerInspector/Version.lua" })
    assert.equals("function", type(ns.readVersion))
  end)
end)
