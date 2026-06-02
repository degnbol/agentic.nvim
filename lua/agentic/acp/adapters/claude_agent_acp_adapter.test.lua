--- @diagnostic disable: invisible, assign-type-mismatch, missing-fields, param-type-mismatch, return-type-mismatch
local assert = require("tests.helpers.assert")

describe("agentic.acp.adapters.ClaudeAgentACPAdapter", function()
    local ClaudeAgentACPAdapter
    local ClaudeShared

    before_each(function()
        ClaudeAgentACPAdapter =
            require("agentic.acp.adapters.claude_agent_acp_adapter")
        ClaudeShared = require("agentic.acp.adapters.claude_shared")
    end)

    --- @return agentic.acp.ACPClient
    local function make_adapter()
        return setmetatable({}, { __index = ClaudeAgentACPAdapter })
    end

    describe("strip_console_fence", function()
        it("strips a ```console wrapper and reports it was fenced", function()
            local inner, was_fenced = ClaudeShared.strip_console_fence({
                "```console",
                "line 01",
                "line 02",
                "```",
            })
            assert.same({ "line 01", "line 02" }, inner)
            assert.is_true(was_fenced)
        end)

        it("leaves unfenced content untouched and reports false", function()
            local inner, was_fenced =
                ClaudeShared.strip_console_fence({ "plain", "text" })
            assert.same({ "plain", "text" }, inner)
            assert.is_false(was_fenced)
        end)

        it("handles nil and too-short bodies", function()
            local n, nf = ClaudeShared.strip_console_fence(nil)
            assert.is_nil(n)
            assert.is_false(nf)
            local s, sf = ClaudeShared.strip_console_fence({ "```console" })
            assert.same({ "```console" }, s)
            assert.is_false(sf)
        end)
    end)

    describe("execute description and body separation", function()
        local CMD = "for i in $(seq 1 30); do printf '%d\\n' \"$i\"; done"
        local DESC = "Print 30 numbered lines to demo execute folding"

        it("lifts the description and drops it from the initial body", function()
            -- Initial tool_call: the bridge sends input.description as content.
            local msg = make_adapter():__build_tool_call_message({
                toolCallId = "tc-1",
                kind = "execute",
                status = "pending",
                title = CMD,
                rawInput = { command = CMD, description = DESC },
                content = {
                    {
                        type = "content",
                        content = { type = "text", text = DESC },
                    },
                },
            })

            assert.equal(DESC, msg.description)
            assert.equal(CMD, msg.argument)
            -- The description echo must not seed the body (which would later
            -- accumulate ahead of the output behind a "---" divider).
            assert.is_nil(msg.body)
        end)

        it(
            "strips the bridge console fence from the completion body",
            function()
                local fenced = { "```console" }
                for i = 1, 30 do
                    table.insert(fenced, string.format("line %02d", i))
                end
                table.insert(fenced, "```")

                local msg = make_adapter():__build_tool_call_update({
                    toolCallId = "tc-1",
                    kind = "execute",
                    status = "completed",
                    rawInput = { command = CMD, description = DESC },
                    content = {
                        {
                            type = "content",
                            content = {
                                type = "text",
                                text = table.concat(fenced, "\n"),
                            },
                        },
                    },
                })

                assert.equal(DESC, msg.description)
                assert.equal(30, #msg.body)
                assert.equal("line 01", msg.body[1])
                assert.equal("line 30", msg.body[30])
                -- No fence lines survive — the renderer applies its own.
                for _, l in ipairs(msg.body) do
                    assert.is_nil(l:match("^```"))
                end
            end
        )
    end)
end)
