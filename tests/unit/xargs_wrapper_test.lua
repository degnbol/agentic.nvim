local assert = require("tests.helpers.assert")
local R = require("agentic.utils.permission_rules")

-- xargs recurses into its literal inner with an always-appended dynamic token
-- ($__xargs_stdin) modelling the runtime stdin items. See the EXEC_WRAPPERS
-- docstring in shell_parse.lua.
describe("xargs exec-wrapper", function()
    local config_dir = vim.fn.tempname()

    it("approves a read-only inner (dynamic token is a no-op)", function()
        assert.is_true(
            R.should_auto_approve("find . | xargs grep foo", config_dir)
        )
    end)

    it("prompts a gated inner: dyn token trips sort's -o gate", function()
        assert.is_false(
            R.should_auto_approve("find . | xargs sort", config_dir)
        )
    end)

    it("auto-rejects a concrete deny inner (rm -rf)", function()
        assert.is_true(
            R.should_auto_reject("find . | xargs rm -rf", config_dir)
        )
    end)

    it("approves standalone xargs of a read-only inner", function()
        assert.is_true(R.should_auto_approve("xargs grep foo", config_dir))
    end)

    it("subsumes the old xargs ls carve-out", function()
        assert.is_true(R.should_auto_approve("xargs ls", config_dir))
    end)
end)
