local assert = require("tests.helpers.assert")
local ToolCallKinds = require("agentic.acp.tool_call_kinds")

describe("agentic.acp.ToolCallKinds", function()
    --- @param id string
    --- @param kind agentic.acp.ToolKind
    --- @return agentic.acp.ToolCallMessage
    local function tool_call(id, kind)
        --- @type agentic.acp.ToolCallMessage
        local update = {
            sessionUpdate = "tool_call",
            toolCallId = id,
            kind = kind,
            title = "",
            status = "pending",
        }
        return update
    end

    --- @param id string
    --- @param fields table|nil
    --- @return agentic.acp.ToolCallUpdate
    local function tool_call_update(id, fields)
        return vim.tbl_extend(
            "force",
            { sessionUpdate = "tool_call_update", toolCallId = id },
            fields or {}
        ) --[[@as agentic.acp.ToolCallUpdate]]
    end

    it("fills an update without kind from the tool_call", function()
        local kinds = ToolCallKinds:new()
        kinds:apply("s", tool_call("t", "edit"))
        local update = tool_call_update("t")
        kinds:apply("s", update)
        assert.equal("edit", update.kind)
    end)

    it("keeps and records a kind an update carries", function()
        local kinds = ToolCallKinds:new()
        kinds:apply("s", tool_call("t", "other"))
        local carrying = tool_call_update("t", { kind = "fetch" })
        kinds:apply("s", carrying)
        assert.equal("fetch", carrying.kind)

        local later = tool_call_update("t")
        kinds:apply("s", later)
        assert.equal("fetch", later.kind)
    end)

    for _, status in ipairs({ "completed", "failed" }) do
        it("fills, then forgets the call at " .. status, function()
            local kinds = ToolCallKinds:new()
            kinds:apply("s", tool_call("t", "read"))
            local terminal = tool_call_update("t", { status = status })
            kinds:apply("s", terminal)
            assert.equal("read", terminal.kind)

            local later = tool_call_update("t")
            kinds:apply("s", later)
            assert.is_nil(later.kind)
        end)
    end

    it("replaces the entry on a second tool_call with the same id", function()
        local kinds = ToolCallKinds:new()
        kinds:apply("s", tool_call("t", "edit"))
        kinds:apply("s", tool_call("t", "think"))
        local update = tool_call_update("t")
        kinds:apply("s", update)
        assert.equal("think", update.kind)
    end)

    it("keeps sessions apart", function()
        local kinds = ToolCallKinds:new()
        kinds:apply("a", tool_call("t", "edit"))
        local other_session = tool_call_update("t")
        kinds:apply("b", other_session)
        assert.is_nil(other_session.kind)
    end)

    it("forget_session drops only that session", function()
        local kinds = ToolCallKinds:new()
        kinds:apply("a", tool_call("t", "edit"))
        kinds:apply("b", tool_call("t", "read"))
        kinds:forget_session("a")

        local in_a = tool_call_update("t")
        kinds:apply("a", in_a)
        assert.is_nil(in_a.kind)

        local in_b = tool_call_update("t")
        kinds:apply("b", in_b)
        assert.equal("read", in_b.kind)
    end)

    it("leaves an update for an unknown id unchanged", function()
        local kinds = ToolCallKinds:new()
        local update = tool_call_update("t", { title = "x" })
        kinds:apply("s", update)
        assert.same(tool_call_update("t", { title = "x" }), update)
    end)
end)
