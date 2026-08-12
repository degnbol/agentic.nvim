--- @diagnostic disable: invisible, assign-type-mismatch, missing-fields, param-type-mismatch, return-type-mismatch
local assert = require("tests.helpers.assert")

describe("agentic.acp.adapters.ClaudeAgentACPAdapter", function()
    local ClaudeAgentACPAdapter
    local ClaudeUtils

    before_each(function()
        ClaudeAgentACPAdapter =
            require("agentic.acp.adapters.claude_agent_acp_adapter")
        ClaudeUtils = require("agentic.acp.adapters.claude_utils")
    end)

    --- @return agentic.acp.ACPClient
    local function make_adapter()
        return setmetatable({}, { __index = ClaudeAgentACPAdapter })
    end

    describe("strip_console_fence", function()
        it("strips a ```console wrapper and reports it was fenced", function()
            local inner, was_fenced = ClaudeUtils.strip_console_fence({
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
                ClaudeUtils.strip_console_fence({ "plain", "text" })
            assert.same({ "plain", "text" }, inner)
            assert.is_false(was_fenced)
        end)

        it("handles nil and too-short bodies", function()
            local n, nf = ClaudeUtils.strip_console_fence(nil)
            assert.is_nil(n)
            assert.is_false(nf)
            local s, sf = ClaudeUtils.strip_console_fence({ "```console" })
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

    describe("edit diff", function()
        -- Subagent (Task) tool calls carry kind + rawInput + content on the
        -- INITIAL tool_call (nothing streams an empty one first), so the diff
        -- must be built there — not only on tool_call_update as for top-level
        -- edits.
        it("builds the diff from content on the tool_call path", function()
            local msg = make_adapter():__build_tool_call_message({
                toolCallId = "tc-edit",
                kind = "edit",
                status = "pending",
                title = "Edit /tmp/f.lua",
                -- Deliberately disagrees with `content` so the assertions
                -- below can only pass if the diff came from `content`.
                rawInput = {
                    file_path = "/tmp/f.lua",
                    old_string = "stale old",
                    new_string = "stale new",
                },
                content = {
                    {
                        type = "diff",
                        path = "/tmp/f.lua",
                        oldText = "old line",
                        newText = "new line",
                    },
                },
            })

            assert.same({ "new line" }, msg.diff.new)
            assert.same({ "old line" }, msg.diff.old)
        end)

        it("carries replace_all from rawInput onto the diff", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-edit",
                kind = "edit",
                rawInput = {
                    file_path = "/tmp/f.lua",
                    old_string = "old line",
                    new_string = "new line",
                    replace_all = true,
                },
                content = {
                    {
                        type = "diff",
                        path = "/tmp/f.lua",
                        oldText = "old line",
                        newText = "new line",
                    },
                },
            })

            assert.is_true(msg.diff.all)
        end)

        -- The bridge streams tool input field-by-field and omits `content`
        -- until the input is complete. A diff built from a half-arrived
        -- rawInput renders as a whole-file deletion and MessageWriter freezes
        -- it, so these updates must produce no diff at all.
        it("builds no diff while the input is still streaming", function()
            local adapter = make_adapter()

            local path_only = adapter:__build_tool_call_update({
                toolCallId = "tc-edit",
                kind = "edit",
                rawInput = { file_path = "/tmp/f.lua" },
            })
            assert.is_nil(path_only.diff)
            assert.equal("/tmp/f.lua", path_only.argument)

            local missing_new = adapter:__build_tool_call_update({
                toolCallId = "tc-edit",
                kind = "edit",
                rawInput = {
                    file_path = "/tmp/f.lua",
                    old_string = "old line",
                },
            })
            assert.is_nil(missing_new.diff)
        end)

        -- A Write over an existing file sends oldText = null; the renderer
        -- resolves the old side from the file itself.
        it("keeps an absent oldText as an empty old side", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-write",
                kind = "edit",
                rawInput = { file_path = "/tmp/f.lua", content = "stale" },
                content = {
                    {
                        type = "diff",
                        path = "/tmp/f.lua",
                        oldText = vim.NIL,
                        newText = "whole file",
                    },
                },
            })

            assert.same({ "whole file" }, msg.diff.new)
            assert.same({}, msg.diff.old)
        end)

        -- A status-text entry can precede the diff (opencode on write/edit
        -- completion), so the scan must not stop at content[1].
        it("finds a diff that is not at content[1]", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-edit",
                kind = "edit",
                rawInput = { file_path = "/tmp/f.lua" },
                content = {
                    {
                        type = "content",
                        content = { type = "text", text = "Wrote file" },
                    },
                    {
                        type = "diff",
                        path = "/tmp/f.lua",
                        oldText = "old line",
                        newText = "new line",
                    },
                },
            })

            assert.same({ "old line" }, msg.diff.old)
        end)
    end)
end)
