local PiPermission = require("agentic.pi.pi_permission")
local assert = require("tests.helpers.assert")

--- @param call table
local function select_request(call)
    return {
        type = "extension_ui_request",
        id = "u1",
        method = "select",
        title = PiPermission.TITLE_PREFIX .. vim.json.encode(call),
        options = PiPermission.OPTION_IDS,
    }
end

describe("agentic.pi.PiPermission", function()
    describe("parse", function()
        it("reads the call from the extension's select", function()
            local call = PiPermission.parse(select_request({
                toolCallId = "c1",
                toolName = "bash",
                input = { command = "ls" },
            }))
            assert.same({
                toolCallId = "c1",
                toolName = "bash",
                input = { command = "ls" },
            }, call)
        end)

        it("is nil for another extension's dialogs", function()
            assert.is_nil(PiPermission.parse({
                method = "select",
                title = "Allow dangerous command?",
                options = { "Allow", "Block" },
            }))
            assert.is_nil(PiPermission.parse({
                method = "confirm",
                title = PiPermission.TITLE_PREFIX .. "{}",
            }))
        end)
    end)

    describe("to_request", function()
        it("resolves the path and offers the four options", function()
            local request = PiPermission.to_request("s1", {
                toolCallId = "c1",
                toolName = "edit",
                input = { path = "a.lua", edits = {} },
            }, "/w")
            assert.equal("s1", request.sessionId)
            assert.same({
                toolCallId = "c1",
                kind = "edit",
                rawInput = { path = "/w/a.lua", edits = {} },
            }, request.toolCall)
            assert.same(
                PiPermission.OPTION_IDS,
                vim.tbl_map(function(o)
                    return o.kind
                end, request.options)
            )
            assert.is_nil(request.safeguard)
        end)

        it("carries the call's auto mode verdict", function()
            local call = PiPermission.parse(select_request({
                toolCallId = "c1",
                toolName = "bash",
                input = { command = "ls" },
                safeguard = { outcome = "not_flagged" },
            })) --[[@as agentic.pi.PiPermission.Call]]
            local request = PiPermission.to_request("s1", call, "/w")
            assert.same({ outcome = "not_flagged" }, request.safeguard)
        end)
    end)

    describe("to_response", function()
        it("answers the option, or cancels", function()
            assert.same(
                { value = "reject_once" },
                PiPermission.to_response("reject_once")
            )
            assert.same({ cancelled = true }, PiPermission.to_response(nil))
        end)
    end)
end)
