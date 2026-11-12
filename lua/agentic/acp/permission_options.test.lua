--- @diagnostic disable: assign-type-mismatch
local assert = require("tests.helpers.assert")

describe("agentic.acp.PermissionOptions", function()
    local PermissionOptions = require("agentic.acp.permission_options")

    --- @type agentic.acp.PermissionOption[]
    local options = {
        { optionId = "proceed_once", name = "Allow", kind = "allow_once" },
        { optionId = "cancel", name = "Reject", kind = " Reject_Once " },
    }

    describe("option_kind", function()
        it("gives the normalised kind of the option the id names", function()
            assert.equal(
                "reject_once",
                PermissionOptions.option_kind(options, "cancel")
            )
        end)

        it("gives an empty string for an unknown id", function()
            assert.equal("", PermissionOptions.option_kind(options, "nope"))
        end)

        it("gives an empty string for a nil id", function()
            assert.equal("", PermissionOptions.option_kind(options, nil))
        end)
    end)
end)
