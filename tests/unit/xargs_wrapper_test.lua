local assert = require("tests.helpers.assert")
local R = require("agentic.utils.permission_rules")

-- xargs recurses into its literal inner with an always-appended dynamic token
-- ($__xargs_stdin) modelling the runtime stdin items. See PLAN-xargs / the
-- EXEC_WRAPPERS docstring in shell_parse.lua.
describe("xargs exec-wrapper", function()
    it("approves a read-only inner (dynamic token is a no-op)", function()
        assert.is_true(R.should_auto_approve("find . | xargs grep foo"))
    end)

    it("prompts a gated inner: dyn token trips sort's -o gate", function()
        assert.is_false(R.should_auto_approve("find . | xargs sort"))
    end)

    it("auto-rejects a concrete deny inner (rm -rf)", function()
        assert.is_true(R.should_auto_reject("find . | xargs rm -rf"))
    end)

    it("approves standalone xargs of a read-only inner", function()
        assert.is_true(R.should_auto_approve("xargs grep foo"))
    end)

    it("subsumes the old xargs ls carve-out", function()
        assert.is_true(R.should_auto_approve("xargs ls"))
    end)
end)
