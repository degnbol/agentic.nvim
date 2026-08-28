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

    describe("PostToolUse hook diff update", function()
        --- Adapter whose subscriber notifications are captured instead of sent.
        --- @return agentic.acp.ACPClient adapter
        --- @return agentic.ui.MessageWriter.ToolCallBase[] updates
        local function make_capturing_adapter()
            --- @type agentic.ui.MessageWriter.ToolCallBase[]
            local updates = {}
            local adapter = setmetatable({
                __with_subscriber = function(_self, _session_id, fn)
                    fn({
                        on_tool_call_update = function(message)
                            table.insert(updates, message)
                        end,
                    })
                end,
            }, { __index = ClaudeAgentACPAdapter })
            return adapter, updates
        end

        --- The hook's notification shape: no status, no rawInput, the tool's
        --- own response under _meta and a content[] rebuilt from its patch.
        --- @param response table
        --- @return agentic.acp.ClaudeAgentToolCallUpdate
        local function hook_update(response)
            return {
                sessionUpdate = "tool_call_update",
                toolCallId = "tc-1",
                _meta = {
                    claudeCode = { toolName = "Write", toolResponse = response },
                },
                content = {
                    {
                        type = "diff",
                        path = response.filePath,
                        oldText = "context",
                        newText = "context",
                    },
                },
                locations = { { path = response.filePath, line = 12 } },
            }
        end

        it("reports a Write that created the file", function()
            local adapter, updates = make_capturing_adapter()

            adapter:__handle_tool_call_update(
                "s-1",
                hook_update({
                    filePath = "/tmp/new.lua",
                    type = "create",
                    structuredPatch = {
                        { newStart = 1, newLines = 3 },
                    },
                })
            )

            assert.equal(1, #updates)
            assert.is_true(updates[1].file_created)
            assert.same(
                { { start_line = 1, end_line = 3 } },
                updates[1].hunk_ranges
            )
        end)

        it("reports a Write over an existing file as not created", function()
            local adapter, updates = make_capturing_adapter()

            adapter:__handle_tool_call_update(
                "s-1",
                hook_update({
                    filePath = "/tmp/old.lua",
                    type = "update",
                    structuredPatch = { { newStart = 5, newLines = 2 } },
                })
            )

            assert.is_false(updates[1].file_created)
        end)

        it(
            "reports an Edit, whose response carries no type, as not created",
            function()
                local adapter, updates = make_capturing_adapter()

                adapter:__handle_tool_call_update(
                    "s-1",
                    hook_update({
                        filePath = "/tmp/old.lua",
                        structuredPatch = { { newStart = 40, newLines = 6 } },
                    })
                )

                assert.is_false(updates[1].file_created)
                assert.same(
                    { { start_line = 40, end_line = 45 } },
                    updates[1].hunk_ranges
                )
            end
        )

        it("keeps one range per hunk", function()
            local adapter, updates = make_capturing_adapter()

            adapter:__handle_tool_call_update(
                "s-1",
                hook_update({
                    filePath = "/tmp/old.lua",
                    structuredPatch = {
                        { newStart = 3, newLines = 2 },
                        { newStart = 90, newLines = 1 },
                    },
                })
            )

            assert.same({
                { start_line = 3, end_line = 4 },
                { start_line = 90, end_line = 90 },
            }, updates[1].hunk_ranges)
        end)

        it(
            "never lets the hook's content[] reach the tracker as a diff",
            function()
                local adapter, updates = make_capturing_adapter()

                adapter:__handle_tool_call_update(
                    "s-1",
                    hook_update({
                        filePath = "/tmp/old.lua",
                        structuredPatch = { { newStart = 1, newLines = 1 } },
                    })
                )

                -- MessageWriter merges list fields element-by-element, so a
                -- hook diff carrying context lines would corrupt the rendered
                -- diff's tracker data.
                assert.is_nil(updates[1].diff)
                assert.is_nil(updates[1].body)
                assert.is_nil(updates[1].status)
            end
        )

        it("degenerates a delete-only hunk to a single line", function()
            local adapter, updates = make_capturing_adapter()

            adapter:__handle_tool_call_update(
                "s-1",
                hook_update({
                    filePath = "/tmp/old.lua",
                    structuredPatch = { { newStart = 7, newLines = 0 } },
                })
            )

            assert.same(
                { { start_line = 7, end_line = 7 } },
                updates[1].hunk_ranges
            )
        end)

        it("leaves a status-bearing update on the normal build path", function()
            local adapter, updates = make_capturing_adapter()

            -- Subagent progress notifications also carry
            -- _meta.claudeCode.toolResponse; only the hook lacks a status.
            adapter:__handle_tool_call_update("s-1", {
                sessionUpdate = "tool_call_update",
                toolCallId = "tc-1",
                status = "in_progress",
                _meta = {
                    claudeCode = {
                        toolName = "Task",
                        toolResponse = { elapsedTimeSeconds = 4 },
                    },
                },
            })

            assert.equal(1, #updates)
            assert.equal("in_progress", updates[1].status)
            assert.is_nil(updates[1].file_created)
        end)

        it("still drops an update with neither status nor rawInput", function()
            local adapter, updates = make_capturing_adapter()

            adapter:__handle_tool_call_update("s-1", {
                sessionUpdate = "tool_call_update",
                toolCallId = "tc-1",
            })

            assert.equal(0, #updates)
        end)
    end)
end)
