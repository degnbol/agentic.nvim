local assert = require("tests.helpers.assert")
local BufferNames = require("agentic.utils.buffer_names")

describe("agentic.utils.BufferNames", function()
    it("reads back every name it formats", function()
        --- @type agentic.BufferNames.Parts[]
        local cases = {
            { key = "8e1f-uuid" },
            { key = "3" },
            { key = "8e1f-uuid", sub_id = "toolu_01ab" },
            { key = "8e1f-uuid", part = "files" },
            { key = "ses_abc", sub_id = "ses_def", part = "input" },
            { key = "8e1f-uuid", part = "background" },
        }
        for _, parts in ipairs(cases) do
            local name = BufferNames.format(parts)
            assert.same(parts, BufferNames.parse(name))
            assert.equal(name, BufferNames.format(BufferNames.parse(name)))
        end
    end)

    it("formats the chat as the key alone", function()
        assert.equal("agentic://abc", BufferNames.format({ key = "abc" }))
    end)

    it("reads each panel as a part", function()
        for _, panel in ipairs(BufferNames.PANELS) do
            assert.same(
                { key = "k", part = panel },
                BufferNames.parse("agentic://k/" .. panel)
            )
        end
    end)

    it("reads any other second segment as a subagent id", function()
        assert.same(
            { key = "k", sub_id = "agent" },
            BufferNames.parse("agentic://k/agent")
        )
    end)

    it("gives an id a short key of 8 hex digits, the same each time", function()
        local key = BufferNames.short_key("toolu_01abc")
        assert.truthy(key:match("^%x%x%x%x%x%x%x%x$"))
        assert.equal(key:lower(), key)
        assert.equal(key, BufferNames.short_key("toolu_01abc"))
        assert.are_not.equal(key, BufferNames.short_key("toolu_01abd"))
    end)

    it("refuses malformed names", function()
        for _, name in ipairs({
            "agentic://",
            "agentic:///files",
            "agentic://k/",
            "agentic://k//input",
            "agentic://k/s/files",
            "agentic://k/files/input",
            "agentic://k/s/input/x",
            "agentic://k/background/input",
            "other://k",
            "/tmp/agentic://k",
        }) do
            assert.is_nil(BufferNames.parse(name))
        end
    end)
end)
