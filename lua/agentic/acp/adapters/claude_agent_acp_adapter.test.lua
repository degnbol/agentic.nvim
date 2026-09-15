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

    --- @param session_roots? table<string, string[]>
    --- @return agentic.acp.ACPClient
    local function make_adapter(session_roots)
        return setmetatable(
            { _session_roots = session_roots or {} },
            { __index = ClaudeAgentACPAdapter }
        )
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

        it(
            "lifts the description and drops it from the initial body",
            function()
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
            end
        )

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
                _session_roots = {},
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

    describe("dispatch on the tool name", function()
        --- Adapter whose initial tool_call notifications are captured.
        --- @return agentic.acp.ACPClient adapter
        --- @return agentic.ui.MessageWriter.ToolCallBlock[] calls
        local function make_capturing_adapter()
            --- @type agentic.ui.MessageWriter.ToolCallBlock[]
            local calls = {}
            local adapter = setmetatable({
                _session_roots = {},
                __with_subscriber = function(_self, _session_id, fn)
                    fn({
                        on_tool_call = function(message)
                            table.insert(calls, message)
                        end,
                    })
                end,
            }, { __index = ClaudeAgentACPAdapter })
            return adapter, calls
        end

        -- Titles are display strings the bridge rewords between releases
        -- (0.75.1: "Skill" → "Load skill: <name>", "ExitPlanMode" →
        -- "Approve Plan"); `_meta.claudeCode.toolName` carries the tool's
        -- own name on every tool-call notification.
        it("mints the Skill kind once the input has streamed", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-skill",
                kind = "other",
                status = "in_progress",
                title = "Load skill: coding",
                rawInput = { skill = "coding", args = "--strict" },
                _meta = { claudeCode = { toolName = "Skill" } },
            })

            assert.equal("Skill", msg.kind)
            assert.equal("coding", msg.argument)
            assert.same({ "--strict" }, msg.body)
        end)

        it("shows a blank argument until the skill name lands", function()
            local adapter, calls = make_capturing_adapter()

            adapter:__handle_tool_call("s-1", {
                sessionUpdate = "tool_call",
                toolCallId = "tc-skill",
                kind = "other",
                status = "pending",
                title = "Load skill",
                rawInput = {},
                _meta = { claudeCode = { toolName = "Skill" } },
            })

            assert.equal("", calls[1].argument)
        end)

        describe("the SKILL.md a Skill call loaded", function()
            --- @type string
            local root
            --- @type string
            local skill_md

            before_each(function()
                root = vim.fn.tempname()
                skill_md =
                    vim.fs.joinpath(root, ".claude/skills/coding/SKILL.md")
                vim.fn.mkdir(vim.fs.dirname(skill_md), "p")
                local file = io.open(skill_md, "w")
                assert.is_not_nil(file)
                --- @cast file -nil
                file:close()
            end)

            after_each(function()
                vim.fs.rm(root, { recursive = true })
            end)

            --- @param skillPath string|nil
            --- @param rawInput table
            --- @return agentic.ui.MessageWriter.ToolCallBase message
            local function skill_update(skillPath, rawInput)
                local adapter = make_adapter({ ["s-1"] = { root } })
                return adapter:__build_tool_call_update({
                    toolCallId = "tc-skill",
                    kind = "other",
                    status = "in_progress",
                    title = "Load skill: coding",
                    rawInput = rawInput,
                    _meta = {
                        claudeCode = {
                            toolName = "Skill",
                            skillPath = skillPath,
                        },
                    },
                }, "s-1")
            end

            it("takes the path the bridge reported", function()
                local reported = vim.fs.joinpath(root, "elsewhere/SKILL.md")
                vim.fn.mkdir(vim.fs.dirname(reported), "p")
                local file = io.open(reported, "w")
                assert.is_not_nil(file)
                --- @cast file -nil
                file:close()

                local msg = skill_update(reported, { skill = "coding" })

                assert.equal(reported, msg.skill_path)
            end)

            it("probes when the reported path names no file", function()
                local msg = skill_update(
                    vim.fs.joinpath(root, "gone/SKILL.md"),
                    { skill = "coding" }
                )

                assert.equal(skill_md, msg.skill_path)
            end)

            -- "unknown skill" is a display sentinel; probing it would search
            -- every root for a skill of that name.
            it("probes nothing before the name streams", function()
                local msg = skill_update(nil, { args = "--strict" })

                assert.equal("unknown skill", msg.argument)
                assert.is_nil(msg.skill_path)
            end)
        end)

        it("renders ExitPlanMode as a switch to Normal", function()
            local adapter, calls = make_capturing_adapter()

            adapter:__handle_tool_call("s-1", {
                sessionUpdate = "tool_call",
                toolCallId = "tc-plan",
                kind = "switch_mode",
                status = "pending",
                title = "Approve Plan",
                content = {
                    {
                        type = "content",
                        content = { type = "text", text = "the plan" },
                    },
                },
                _meta = { claudeCode = { toolName = "ExitPlanMode" } },
            })

            assert.equal(1, #calls)
            assert.equal("switch_mode", calls[1].kind)
            assert.equal("Normal", calls[1].argument)
            -- The body holds internal instructions, not user-facing content.
            assert.is_nil(calls[1].body)
        end)

        -- The bridge has no formatter for SlashCommand, so its title is the
        -- bare tool name — the glyph's job, not the head's.
        it("clears the SlashCommand title until the command lands", function()
            local adapter, calls = make_capturing_adapter()

            adapter:__handle_tool_call("s-1", {
                sessionUpdate = "tool_call",
                toolCallId = "tc-cmd",
                kind = "other",
                status = "pending",
                title = "SlashCommand",
                rawInput = {},
                _meta = { claudeCode = { toolName = "SlashCommand" } },
            })

            assert.equal("SlashCommand", calls[1].kind)
            assert.equal("", calls[1].argument)
        end)

        it("heads a SlashCommand call with the command line", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-cmd",
                kind = "other",
                status = "in_progress",
                title = "SlashCommand",
                rawInput = { command = "/review --fix" },
                _meta = { claudeCode = { toolName = "SlashCommand" } },
            })

            assert.equal("SlashCommand", msg.kind)
            assert.equal("/review --fix", msg.argument)
        end)

        -- A streamed top-level call carries an empty rawInput on its initial
        -- tool_call, and `_on_tool_call` persists `kind` on that phase alone.
        it("mints the kind before any input has streamed", function()
            local adapter, calls = make_capturing_adapter()

            adapter:__handle_tool_call("s-1", {
                sessionUpdate = "tool_call",
                toolCallId = "tc-search",
                kind = "other",
                status = "pending",
                title = "ToolSearch",
                rawInput = {},
                _meta = { claudeCode = { toolName = "ToolSearch" } },
            })

            assert.equal("ToolSearch", calls[1].kind)
            -- The bridge's title is the tool's own name, which the glyph says.
            assert.equal("", calls[1].argument)
        end)

        it("heads a tool search with its query", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-search",
                kind = "other",
                status = "in_progress",
                title = "ToolSearch",
                rawInput = { query = "select:Read,Edit" },
                _meta = { claudeCode = { toolName = "ToolSearch" } },
            })

            assert.equal("ToolSearch", msg.kind)
            assert.equal("select:Read,Edit", msg.argument)
        end)

        it("leaves ListAgents bare through both phases", function()
            local adapter, calls = make_capturing_adapter()

            adapter:__handle_tool_call("s-1", {
                sessionUpdate = "tool_call",
                toolCallId = "tc-agents",
                kind = "other",
                status = "pending",
                title = "ListAgents",
                rawInput = {},
                _meta = { claudeCode = { toolName = "ListAgents" } },
            })
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-agents",
                kind = "other",
                status = "completed",
                rawInput = { channel = "" },
                _meta = { claudeCode = { toolName = "ListAgents" } },
            })

            assert.equal("ListAgents", calls[1].kind)
            assert.equal("", calls[1].argument)
            assert.equal("ListAgents", msg.kind)
            -- Nothing to clear on an update, so the head the initial call
            -- established stands through the merge.
            assert.is_nil(msg.argument)
        end)

        -- The refined head has to survive the terminal update, which carries
        -- status and content but no rawInput to rebuild it from.
        it("keeps a refined head off the completed update", function()
            local adapter = make_adapter()
            local refined = adapter:__build_tool_call_update({
                toolCallId = "tc-search",
                kind = "other",
                status = "in_progress",
                rawInput = { query = "select:Read" },
                _meta = { claudeCode = { toolName = "ToolSearch" } },
            })
            local completed = adapter:__build_tool_call_update({
                toolCallId = "tc-search",
                kind = "other",
                status = "completed",
                content = {
                    {
                        type = "content",
                        content = { type = "text", text = "1 tool" },
                    },
                },
                _meta = { claudeCode = { toolName = "ToolSearch" } },
            })

            assert.equal("select:Read", refined.argument)
            assert.is_nil(completed.argument)
        end)

        it("heads a monitor with its description", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-monitor",
                kind = "other",
                status = "in_progress",
                title = "Monitor",
                rawInput = { description = "Wait for the CI run" },
                _meta = { claudeCode = { toolName = "Monitor" } },
            })

            assert.equal("Monitor", msg.kind)
            assert.equal("Wait for the CI run", msg.argument)
        end)

        describe("SendMessage", function()
            --- @param rawInput table
            --- @return agentic.ui.MessageWriter.ToolCallBase message
            local function message_update(rawInput)
                return make_adapter():__build_tool_call_update({
                    toolCallId = "tc-msg",
                    kind = "other",
                    status = "in_progress",
                    title = "SendMessage",
                    rawInput = rawInput,
                    _meta = { claudeCode = { toolName = "SendMessage" } },
                })
            end

            it("names the addressee alone", function()
                local msg = message_update({ to = "code-reviewer" })

                assert.equal("SendMessage", msg.kind)
                assert.equal("code-reviewer", msg.argument)
            end)

            it("adds the summary when both are present", function()
                local msg = message_update({
                    to = "code-reviewer",
                    summary = "ask about the fold anchor",
                })

                assert.equal(
                    "code-reviewer: ask about the fold anchor",
                    msg.argument
                )
            end)
        end)

        describe("the task-control family", function()
            --- @param toolName string
            --- @param rawInput table
            --- @return agentic.ui.MessageWriter.ToolCallBase message
            local function task_update(toolName, rawInput)
                return make_adapter():__build_tool_call_update({
                    toolCallId = "tc-task",
                    kind = "other",
                    status = "in_progress",
                    title = toolName,
                    rawInput = rawInput,
                    _meta = { claudeCode = { toolName = toolName } },
                })
            end

            -- One glyph covers the family, so the head has to name which
            -- operation ran.
            it("keeps the operation in the head", function()
                local stop = task_update("TaskStop", { task_id = "t-7" })
                local output = task_update("TaskOutput", { task_id = "t-7" })

                assert.equal("TaskControl", stop.kind)
                assert.equal("TaskStop: t-7", stop.argument)
                assert.equal("TaskControl", output.kind)
                assert.equal("TaskOutput: t-7", output.argument)
            end)

            -- `task_id` is optional on TaskStop (it stops every task without
            -- one), so the name-only head is the whole head, not a prefix
            -- waiting for a field.
            it("renders name-only without a task id", function()
                local msg = task_update("TaskStop", { description = "halt" })

                assert.equal("TaskStop", msg.argument)
            end)
        end)

        it("heads a cron deletion with the tool name alone", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-cron",
                kind = "other",
                status = "in_progress",
                title = "CronDelete",
                rawInput = { id = "cron-3" },
                _meta = { claudeCode = { toolName = "CronDelete" } },
            })

            assert.equal("Cron", msg.kind)
            assert.equal("CronDelete", msg.argument)
        end)

        it("heads a cron creation with the schedule", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-cron",
                kind = "other",
                status = "in_progress",
                title = "CronCreate",
                rawInput = { cron = "0 9 * * 1" },
                _meta = { claudeCode = { toolName = "CronCreate" } },
            })

            assert.equal("Cron", msg.kind)
            assert.equal("CronCreate: 0 9 * * 1", msg.argument)
        end)

        it("splits an MCP name into server and tool", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-mcp",
                kind = "other",
                status = "in_progress",
                title = "mcp__cclsp__rename_symbol",
                rawInput = { file_path = "/tmp/a.lua" },
                _meta = {
                    claudeCode = { toolName = "mcp__cclsp__rename_symbol" },
                },
            })

            assert.equal("Mcp", msg.kind)
            assert.equal("cclsp: rename_symbol", msg.argument)
        end)

        -- The `mcp__` population is unbounded, so a kind the bridge did have a
        -- formatter for is richer than anything a name can derive.
        it("leaves an MCP tool the bridge kinded alone", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-mcp",
                kind = "read",
                status = "in_progress",
                title = "Read /tmp/a.lua",
                rawInput = { file_path = "/tmp/a.lua" },
                _meta = {
                    claudeCode = { toolName = "mcp__filesystem__read_file" },
                },
            })

            assert.is_nil(msg.kind)
            assert.equal("/tmp/a.lua", msg.argument)
        end)

        it("leaves an unlisted tool name on the generic path", function()
            local msg = make_adapter():__build_tool_call_update({
                toolCallId = "tc-report",
                kind = "other",
                status = "in_progress",
                title = "ReportFindings",
                rawInput = { level = "high" },
                _meta = { claudeCode = { toolName = "ReportFindings" } },
            })

            assert.is_nil(msg.kind)
            assert.equal("ReportFindings", msg.argument)
        end)

        -- A minted kind with no glyph renders a silent gear, which neither the
        -- adapter nor the glyph module can see on its own.
        it("mints no kind without a glyph", function()
            local Glyphs = require("agentic.glyphs")
            local AcpKind = require("agentic.utils.acp_kind")

            local kinds = vim.tbl_values(ClaudeUtils.TOOL_KINDS)
            table.insert(
                kinds,
                ClaudeUtils.tool_kind("mcp__cclsp__rename_symbol", "other")
            )

            --- @type string[]
            local glyphless = {}
            for _, kind in ipairs(kinds) do
                if not Glyphs.KIND[AcpKind.normalise(kind)] then
                    table.insert(glyphless, kind)
                end
            end

            assert.same({}, glyphless)
        end)

        -- The bridge's untracked-tool fallback sends no `_meta` at all, and a
        -- title alone must no longer reach a mode-switch branch.
        it("leaves a notification without _meta on the generic path", function()
            local adapter, calls = make_capturing_adapter()

            adapter:__handle_tool_call("s-1", {
                sessionUpdate = "tool_call",
                toolCallId = "tc-other",
                kind = "other",
                status = "pending",
                title = "Approve Plan",
            })

            assert.equal("other", calls[1].kind)
            assert.equal("Approve Plan", calls[1].argument)
        end)
    end)

    describe("subagent heading", function()
        --- @param rawInput table
        --- @return agentic.ui.MessageWriter.ToolCallBase message
        local function think_update(rawInput)
            return make_adapter():__build_tool_call_update({
                toolCallId = "tc-task",
                kind = "think",
                status = "in_progress",
                title = "Review the diff",
                rawInput = rawInput,
            })
        end

        it("names the agent ahead of the description", function()
            local msg = think_update({
                subagent_type = "code-reviewer",
                description = "Review the diff",
            })

            assert.equal("SubAgent", msg.kind)
            assert.equal("code-reviewer: Review the diff", msg.argument)
        end)

        it("falls back to the bare type before a description lands", function()
            local msg = think_update({ subagent_type = "code-reviewer" })

            assert.equal("SubAgent", msg.kind)
            assert.equal("code-reviewer", msg.argument)
        end)

        it("treats an empty description as absent", function()
            local msg = think_update({
                subagent_type = "code-reviewer",
                description = "",
            })

            assert.equal("code-reviewer", msg.argument)
        end)

        -- Guards the branch order: a think call without a subagent_type is a
        -- plain thought and must not take the SubAgent branch.
        it("leaves a think call without a type alone", function()
            local msg = think_update({ description = "Review the diff" })

            assert.is_nil(msg.kind)
        end)
    end)

    describe("new", function()
        local Config
        local original_todo_tools

        before_each(function()
            Config = require("agentic.config")
            original_todo_tools = Config.todo_tools
        end)

        after_each(function()
            Config.todo_tools = original_todo_tools
        end)

        --- Construct through a subclass that stubs out the subprocess, and
        --- report the provider config the transport would have spawned with.
        --- @param provider_config agentic.acp.ACPProviderConfig
        --- @return agentic.acp.ACPProviderConfig
        local function spawn_config(provider_config)
            local captured
            local Stub = setmetatable({}, { __index = ClaudeAgentACPAdapter })
            Stub.__index = Stub
            function Stub:_setup_transport()
                captured = self.provider_config
            end
            function Stub:_connect() end

            Stub:new(provider_config, function() end)
            return captured
        end

        it("enables the todo tools in the provider env", function()
            Config.todo_tools = true

            local config = spawn_config({ command = "claude-agent-acp" })

            assert.equal("1", config.env.CLAUDE_CODE_ENABLE_TODO_TOOLS)
        end)

        it("leaves the env alone when the todo tools are off", function()
            Config.todo_tools = false

            local config =
                spawn_config({ command = "claude-agent-acp", env = {} })

            assert.is_nil(config.env.CLAUDE_CODE_ENABLE_TODO_TOOLS)
        end)

        it("yields to an explicit env entry", function()
            Config.todo_tools = true

            local config = spawn_config({
                command = "claude-agent-acp",
                env = { CLAUDE_CODE_ENABLE_TODO_TOOLS = "0" },
            })

            assert.equal("0", config.env.CLAUDE_CODE_ENABLE_TODO_TOOLS)
        end)
    end)
end)
