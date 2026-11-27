local assert = require("tests.helpers.assert")

local ToolTimings = require("agentic.tool_timings")

describe("agentic.ToolTimings", function()
    describe("prompt_text", function()
        it("is nil without reports", function()
            assert.is_nil(ToolTimings.prompt_text({}, {}, 5000))
        end)

        it("lists the calls longest first", function()
            local blocks = {
                a = {
                    tool_call_id = "a",
                    kind = "execute",
                    argument = "make test\nmore",
                    status = "completed",
                },
                b = {
                    tool_call_id = "b",
                    kind = "fetch",
                    argument = "https://x",
                    status = "failed",
                    ended_as = "interrupted",
                },
            }
            local text = ToolTimings.prompt_text({
                { id = "b", ms = 6000 },
                { id = "a", ms = 192000 },
            }, blocks, 5000)
            assert.equal(
                table.concat({
                    "<tool_timings>",
                    "Run time the editor measured for your tool calls that took 5.0 s or longer since the previous prompt:",
                    "- a execute `make test`: 3m12s, completed",
                    "- b fetch `https://x`: 6.0 s, interrupted",
                    "</tool_timings>",
                }, "\n"),
                text
            )
        end)

        it("gives the id and time of a call without a block", function()
            local text = ToolTimings.prompt_text(
                { { id = "gone", ms = 7000 } },
                {},
                5000
            )
            assert.truthy(text and text:find("\n%- gone: 7%.0 s\n"))
        end)

        it("cuts a long argument", function()
            local blocks = {
                a = {
                    tool_call_id = "a",
                    kind = "execute",
                    argument = string.rep("x", 200),
                    status = "completed",
                },
            }
            local text = ToolTimings.prompt_text(
                { { id = "a", ms = 7000 } },
                blocks,
                5000
            )
            local span = (text or ""):match("\n%- a execute `([^`]*)`")
            assert.equal(80, vim.api.nvim_strwidth(span))
        end)
    end)
end)
