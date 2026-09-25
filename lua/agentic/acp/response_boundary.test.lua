local assert = require("tests.helpers.assert")
local ResponseBoundary = require("agentic.acp.response_boundary")

describe("agentic.acp.ResponseBoundary", function()
    --- Run `chunks` through one boundary and collect each verdict.
    --- @param chunks { [1]: string|nil, [2]: string }[] `{ message_id, text }` pairs
    --- @return { [1]: string, [2]: boolean }[] verdicts `{ text, starts_response }` per chunk
    local function run(chunks)
        local boundary = ResponseBoundary:new()
        local verdicts = {}
        for _, chunk in ipairs(chunks) do
            local text, starts = boundary:filter(chunk[1], chunk[2])
            table.insert(verdicts, { text, starts })
        end
        return verdicts
    end

    it("does not start a response on the first id", function()
        assert.same({ { "a", false } }, run({ { "X", "a" } }))
    end)

    it("does not start a response within one id", function()
        assert.same(
            { { "a", false }, { "b", false } },
            run({ { "X", "a" }, { "X", "b" } })
        )
    end)

    it("starts a response when the id changes", function()
        assert.same(
            { { "a", false }, { "b", true } },
            run({ { "X", "a" }, { "Y", "b" } })
        )
    end)

    it("compares across a chunk with no id", function()
        assert.same(
            { { "a", false }, { "b", false }, { "c", true } },
            run({ { "X", "a" }, { nil, "b" }, { "Y", "c" } })
        )
    end)

    it("strips leading newlines split over several chunks", function()
        assert.same(
            { { "a", false }, { "", false }, { "foo", true } },
            run({ { "X", "a" }, { "Y", "\n" }, { "Y", "\nfoo" } })
        )
    end)

    it("stops stripping at the first chunk with text, whatever its id", function()
        assert.same({
            { "a", false },
            { "", false },
            { "foo", true },
            { "\nbar", false },
        }, run({
            { "X", "a" },
            { "Y", "\n" },
            { nil, "foo" },
            { "Y", "\nbar" },
        }))
    end)
end)
