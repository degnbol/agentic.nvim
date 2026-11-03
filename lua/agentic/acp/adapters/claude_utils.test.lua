local assert = require("tests.helpers.assert")

local ClaudeUtils = require("agentic.acp.adapters.claude_utils")

describe("agentic.acp.adapters.ClaudeUtils", function()
    describe("send_message_instruction", function()
        it("names the agent id, label and message", function()
            assert.equal(
                'Call SendMessage with to: "a1b2" and message: "focus on tests", to message the background subagent "Explore auth". Send the message verbatim and do nothing else. Do not reply nor report back what you did.',
                ClaudeUtils.send_message_instruction(
                    "a1b2",
                    "Explore auth",
                    "focus on tests"
                )
            )
        end)

        it("keeps a multi-line message on one line", function()
            local text =
                ClaudeUtils.send_message_instruction("a1", "x", 'one\n"two"')
            assert.is_nil(text:find("\n", 1, true))
            assert.is_true(text:find('"one\\n\\"two\\""', 1, true) ~= nil)
        end)
    end)

    describe("stopped_task", function()
        it("reads task_id, else shell_id", function()
            assert.equal("t-7", ClaudeUtils.stopped_task({ task_id = "t-7" }))
            assert.equal("s-2", ClaudeUtils.stopped_task({ shell_id = "s-2" }))
        end)

        it("gives nil for an empty or absent id", function()
            assert.is_nil(ClaudeUtils.stopped_task({ task_id = "" }))
            assert.is_nil(ClaudeUtils.stopped_task({}))
        end)
    end)

    describe("task_stop_result", function()
        it("reads the task id of a result", function()
            assert.equal(
                "bdod3zl0w",
                ClaudeUtils.task_stop_result({
                    '{"message":"Successfully stopped task: bdod3zl0w","task_id":"bdod3zl0w","task_type":"local_bash"}',
                })
            )
        end)

        it("gives nil for a body that is not such an object", function()
            assert.is_nil(ClaudeUtils.task_stop_result({ "No task found" }))
            assert.is_nil(ClaudeUtils.task_stop_result({ '{"message":"x"}' }))
            assert.is_nil(ClaudeUtils.task_stop_result(nil))
        end)
    end)

    describe("background_task", function()
        local path = "/private/tmp/claude-501/proj/tasks/b7x2k9.output"

        it("reads the id and path of each local wording", function()
            for _, text in ipairs({
                "Command running in background with ID: b7x2k9. Output is being written to: "
                    .. path
                    .. ".",
                "Command was manually backgrounded by user with ID: b7x2k9. Output is being written to: "
                    .. path,
                "Command was moved to the background (ID: b7x2k9) so that it does not block. Output is being written to: "
                    .. path
                    .. ".",
            }) do
                local task_id, output_path = ClaudeUtils.background_task(text)
                assert.equal("b7x2k9", task_id)
                assert.equal(path, output_path)
            end
        end)

        it("gives nil for a task on a remote host", function()
            assert.is_nil(
                ClaudeUtils.background_task(
                    "Command running in the background on devbox with ID: b7x2k9. Output is being written there to: "
                        .. path
                )
            )
        end)

        it("keeps spaces in the path", function()
            local spaced = "/tmp/my dir/tasks/b7x2k9.output"
            local _, output_path = ClaudeUtils.background_task(
                "Command running in background with ID: b7x2k9. Output is being written to: "
                    .. spaced
                    .. "."
            )
            assert.equal(spaced, output_path)
        end)

        it("gives nil for output that only mentions a task path", function()
            assert.is_nil(
                ClaudeUtils.background_task(
                    "log: Output is being written to: " .. path
                )
            )
        end)

        it("gives nil for text without a path", function()
            assert.is_nil(
                ClaudeUtils.background_task(
                    "Command running in background with ID: b7x2k9."
                )
            )
        end)
    end)

    describe("list_agents_result", function()
        local PEERS = {
            "Peer sessions (2):",
            "  other-01 [aa11]  idle",
        }

        it("splits off this session's line", function()
            local token, rest = ClaudeUtils.list_agents_result({
                "This session is agentic-nvim-06 [da37b0] — the name other sessions use to message it (…).",
                "",
                PEERS[1],
                PEERS[2],
            })
            assert.equal("agentic-nvim-06 [da37b0]", token)
            assert.same(PEERS, rest)
        end)

        it("reads the form a subagent gets", function()
            local token, rest = ClaudeUtils.list_agents_result({
                "This process's main session is agentic-nvim-06 [da37b0] — the name OTHER sessions use to message it (…).",
                PEERS[1],
            })
            assert.equal("agentic-nvim-06 [da37b0]", token)
            assert.same({ PEERS[1] }, rest)
        end)

        it("returns no rest when only the self line is there", function()
            local token, rest = ClaudeUtils.list_agents_result({
                "This session is agentic-nvim-06 [da37b0] — the name other sessions use to message it (…).",
                "",
            })
            assert.equal("agentic-nvim-06 [da37b0]", token)
            assert.is_nil(rest)
        end)

        it("returns nothing without a self line", function()
            local token, rest = ClaudeUtils.list_agents_result(PEERS)
            assert.is_nil(token)
            assert.is_nil(rest)
        end)

        it("returns nothing for no body", function()
            local token, rest = ClaudeUtils.list_agents_result(nil)
            assert.is_nil(token)
            assert.is_nil(rest)
        end)
    end)

    describe("unwrap_tool_use_error", function()
        it("unwraps a one-line element", function()
            assert.same(
                { "File not found" },
                ClaudeUtils.unwrap_tool_use_error({
                    "<tool_use_error>File not found</tool_use_error>",
                })
            )
        end)

        it("unwraps a multi-line element", function()
            assert.same(
                { "Found 10 matches of the string.", "Use replace_all." },
                ClaudeUtils.unwrap_tool_use_error({
                    "<tool_use_error>Found 10 matches of the string.",
                    "Use replace_all.</tool_use_error>",
                })
            )
        end)

        it("unwraps despite a trailing empty line", function()
            assert.same(
                { "X" },
                ClaudeUtils.unwrap_tool_use_error({
                    "<tool_use_error>X</tool_use_error>",
                    "",
                })
            )
        end)

        it("returns nil for an element holding only whitespace", function()
            assert.is_nil(ClaudeUtils.unwrap_tool_use_error({
                "<tool_use_error> </tool_use_error>",
            }))
        end)

        it("leaves lines without the envelope unchanged", function()
            local cases = {
                { "plain error" },
                { "<tool_use_error>no closing tag" },
                { "see <tool_use_error>X</tool_use_error> here" },
            }
            for _, lines in ipairs(cases) do
                assert.same(lines, ClaudeUtils.unwrap_tool_use_error(lines))
            end
        end)
    end)

    describe("send_message_update", function()
        it(
            "heads the call with addressee and summary, bodies the message",
            function()
                assert.same(
                    {
                        tool_call_id = "toolu_1",
                        argument = "agentic-nvim-c5: Tell peer",
                        body = { "line 1", "line 2" },
                    },
                    ClaudeUtils.send_message_update("toolu_1", {
                        to = "agentic-nvim-c5",
                        summary = "Tell peer",
                        message = "line 1\nline 2",
                    })
                )
            end
        )

        it("gives no body without a message", function()
            local update =
                ClaudeUtils.send_message_update("toolu_1", { to = "peer" })
            assert.equal("peer", update.argument)
            assert.is_nil(update.body)
        end)
    end)

    describe("config_dir", function()
        it("prefers the provider's env", function()
            assert.equal(
                "/tmp/from-env",
                ClaudeUtils.config_dir({ CLAUDE_CONFIG_DIR = "/tmp/from-env" })
            )
        end)

        it("falls back to ~/.claude", function()
            local saved = vim.env.CLAUDE_CONFIG_DIR
            vim.env.CLAUDE_CONFIG_DIR = nil
            local dir = ClaudeUtils.config_dir(nil)
            vim.env.CLAUDE_CONFIG_DIR = saved
            assert.equal(vim.fs.normalize("~/.claude"), dir)
        end)
    end)

    describe("exec_shell", function()
        local orig_shell
        local orig_code_shell

        before_each(function()
            orig_shell = vim.env.SHELL
            orig_code_shell = vim.env.CLAUDE_CODE_SHELL
            vim.env.SHELL = nil
            vim.env.CLAUDE_CODE_SHELL = nil
        end)

        after_each(function()
            vim.env.SHELL = orig_shell
            vim.env.CLAUDE_CODE_SHELL = orig_code_shell
        end)

        it("prefers CLAUDE_CODE_SHELL over SHELL", function()
            vim.env.CLAUDE_CODE_SHELL = "/bin/zsh"
            vim.env.SHELL = "/bin/bash"
            assert.equal("zsh", ClaudeUtils.exec_shell(nil))
        end)

        it("falls back to SHELL when no override", function()
            vim.env.SHELL = "/bin/bash"
            assert.equal("bash", ClaudeUtils.exec_shell(nil))
        end)

        it("returns nil for a SHELL naming an unknown shell", function()
            vim.env.SHELL = "/usr/bin/fish"
            assert.is_nil(ClaudeUtils.exec_shell(nil))
        end)

        it("returns nil for a known shell that is not executable", function()
            vim.env.SHELL = "/nonexistent/bash"
            assert.is_nil(ClaudeUtils.exec_shell(nil))
        end)

        it("returns nil when SHELL is unset and no override", function()
            assert.is_nil(ClaudeUtils.exec_shell({}))
        end)

        it("reads the provider env over the editor's", function()
            vim.env.SHELL = "/bin/zsh"
            assert.equal(
                "bash",
                ClaudeUtils.exec_shell({ SHELL = "/bin/bash" })
            )
        end)
    end)

    describe("session files", function()
        local session_id = "0b8f5c2e-1111-2222-3333-444455556666"
        --- @type string
        local config_dir
        --- @type string
        local session_dir

        before_each(function()
            config_dir = vim.fn.tempname()
            session_dir =
                vim.fs.joinpath(config_dir, "projects", "-tmp-b", session_id)
            vim.fn.mkdir(vim.fs.joinpath(config_dir, "projects", "-tmp-a"), "p")
            vim.fn.mkdir(vim.fs.joinpath(session_dir, "subagents"), "p")
            vim.fn.writefile(
                {},
                vim.fs.joinpath(
                    config_dir,
                    "projects",
                    "-tmp-b",
                    session_id .. ".jsonl"
                )
            )
        end)

        after_each(function()
            vim.fs.rm(config_dir, { recursive = true })
        end)

        it("finds a session in any project directory", function()
            assert.equal(
                session_dir,
                ClaudeUtils.find_session_dir(config_dir, session_id)
            )
        end)

        it("finds no directory for an unknown session", function()
            assert.is_nil(ClaudeUtils.find_session_dir(config_dir, "nope"))
        end)

        it("finds a transcript in any project directory", function()
            assert.equal(
                session_dir .. ".jsonl",
                ClaudeUtils.find_transcript(config_dir, session_id)
            )
        end)

        it("finds no transcript before the CLI writes it", function()
            assert.is_nil(ClaudeUtils.find_transcript(config_dir, "nope"))
        end)

        --- @param agent_id string
        --- @param lines string[]
        local function write_meta(agent_id, lines)
            vim.fn.writefile(
                lines,
                vim.fs.joinpath(
                    session_dir,
                    "subagents",
                    "agent-" .. agent_id .. ".meta.json"
                )
            )
        end

        it("decodes a subagent's meta file", function()
            write_meta("a1", {
                vim.json.encode({
                    agentType = "Explore",
                    description = "d",
                    toolUseId = "toolu_1",
                    spawnDepth = 1,
                    requestShape = "background",
                }),
            })

            assert.same({
                agent_type = "Explore",
                request_shape = "background",
                tool_use_id = "toolu_1",
            }, ClaudeUtils.subagent_meta(session_dir, "a1"))
        end)

        it("returns nil for a missing meta file", function()
            assert.is_nil(ClaudeUtils.subagent_meta(session_dir, "a2"))
        end)

        it("returns nil for a malformed meta file", function()
            write_meta("a3", { "{not json" })
            assert.is_nil(ClaudeUtils.subagent_meta(session_dir, "a3"))
        end)

        it("returns nil for a meta file without the fields", function()
            write_meta("a4", { "[]" })
            assert.is_nil(ClaudeUtils.subagent_meta(session_dir, "a4"))
        end)

        describe("process_name", function()
            --- @param pid integer
            --- @param lines string[]
            local function write_process(pid, lines)
                local dir = vim.fs.joinpath(config_dir, "sessions")
                vim.fn.mkdir(dir, "p")
                vim.fn.writefile(lines, vim.fs.joinpath(dir, pid .. ".json"))
            end

            --- A process file, run by this process unless `fields` gives a pid.
            --- @param file_id integer
            --- @param fields table
            local function write_entry(file_id, fields)
                fields.pid = fields.pid or vim.uv.os_getpid()
                write_process(file_id, { vim.json.encode(fields) })
            end

            it("reads the name of the process running the session", function()
                write_entry(1, {
                    sessionId = "other",
                    startedAt = 5,
                    name = "agentic-nvim-01",
                })
                write_entry(2, {
                    sessionId = session_id,
                    startedAt = 1,
                    name = "agentic-nvim-02",
                })
                write_process(3, { "{torn" })

                assert.equal(
                    "agentic-nvim-02",
                    ClaudeUtils.process_name(config_dir, session_id)
                )
            end)

            it("takes the newest of two processes", function()
                write_entry(1, {
                    sessionId = session_id,
                    startedAt = 2,
                    name = "agentic-nvim-new",
                })
                write_entry(2, {
                    sessionId = session_id,
                    startedAt = 1,
                    name = "agentic-nvim-old",
                })

                assert.equal(
                    "agentic-nvim-new",
                    ClaudeUtils.process_name(config_dir, session_id)
                )
            end)

            it("skips the file of a process that has exited", function()
                local exited = vim.system({ "true" })
                exited:wait()
                write_entry(1, {
                    sessionId = session_id,
                    startedAt = 2,
                    pid = exited.pid,
                    name = "agentic-nvim-crashed",
                })
                write_entry(2, {
                    sessionId = session_id,
                    startedAt = 1,
                    name = "agentic-nvim-live",
                })

                assert.equal(
                    "agentic-nvim-live",
                    ClaudeUtils.process_name(config_dir, session_id)
                )
            end)

            it("has no name when the newest process has none", function()
                write_entry(1, {
                    sessionId = session_id,
                    startedAt = 1,
                    name = "agentic-nvim-old",
                })
                write_entry(2, { sessionId = session_id, startedAt = 2 })
                assert.is_nil(ClaudeUtils.process_name(config_dir, session_id))

                write_entry(2, {
                    sessionId = session_id,
                    startedAt = 2,
                    name = "",
                })
                assert.is_nil(ClaudeUtils.process_name(config_dir, session_id))
            end)

            it("has no name without a sessions directory", function()
                assert.is_nil(ClaudeUtils.process_name(config_dir, session_id))
            end)
        end)
    end)

    describe("budget_windows", function()
        it("reads both windows, shortest first", function()
            local windows = ClaudeUtils.budget_windows({
                unifiedWindows = {
                    seven_day = { utilization = 0.54, resetsAt = 2000 },
                    five_hour = { utilization = 0.03, resetsAt = 1000 },
                },
            })
            assert.same({
                {
                    label = "5h",
                    utilization = 0.03,
                    resets_at = 1000,
                    window_s = 5 * 3600,
                    state = "ok",
                },
                {
                    label = "7d",
                    utilization = 0.54,
                    resets_at = 2000,
                    window_s = 7 * 24 * 3600,
                    state = "ok",
                },
            }, windows)
        end)

        it("reads milliseconds", function()
            local windows = ClaudeUtils.budget_windows({
                unifiedWindows = {
                    five_hour = { utilization = 0.42, resetsAt = 1.7e12 },
                },
            }) --[[@as agentic.acp.BudgetWindow[] ]]
            assert.equal(1.7e9, windows[1].resets_at)
        end)

        it("takes the state from the entry", function()
            local windows = ClaudeUtils.budget_windows({
                status = "allowed",
                rateLimitType = "five_hour",
                unifiedWindows = {
                    five_hour = {
                        utilization = 1,
                        resetsAt = 1000,
                        status = "rejected",
                    },
                    seven_day = {
                        utilization = 0.9,
                        resetsAt = 2000,
                        status = "allowed_warning",
                    },
                },
            }) --[[@as agentic.acp.BudgetWindow[] ]]
            assert.equal("exhausted", windows[1].state)
            assert.equal("warning", windows[2].state)
        end)

        it(
            "takes the state from the top level for the binding window",
            function()
                local windows = ClaudeUtils.budget_windows({
                    status = "allowed_warning",
                    rateLimitType = "seven_day",
                    unifiedWindows = {
                        five_hour = { utilization = 0.1, resetsAt = 1000 },
                        seven_day = { utilization = 0.9, resetsAt = 2000 },
                    },
                }) --[[@as agentic.acp.BudgetWindow[] ]]
                assert.equal("ok", windows[1].state)
                assert.equal("warning", windows[2].state)
            end
        )

        it("skips unknown keys and unreadable entries", function()
            local windows = ClaudeUtils.budget_windows({
                unifiedWindows = {
                    seven_day_overage_included = {
                        utilization = 0.5,
                        resetsAt = 3000,
                    },
                    five_hour = { resetsAt = 1000 },
                    seven_day = { utilization = 0.5, resetsAt = 2000 },
                },
            }) --[[@as agentic.acp.BudgetWindow[] ]]
            assert.equal(1, #windows)
            assert.equal("7d", windows[1].label)
        end)

        it("returns nil without unifiedWindows", function()
            assert.is_nil(ClaudeUtils.budget_windows({
                rateLimitType = "five_hour",
                utilization = 0.5,
                resetsAt = 1000,
            }))
        end)
    end)

    describe("denial_line", function()
        for reason_type, label in pairs({
            rule = "Rejected by a permission rule",
            subcommandResults = "Rejected by a permission rule for part of the command",
            mode = "Rejected by the permission mode",
            classifier = "Rejected by the auto-mode classifier",
            asyncAgent = "Rejected: no permission prompt here",
            workingDir = "Rejected: outside the allowed directories",
            safetyCheck = "Rejected by a safety check",
            sandboxOverride = "Rejected by the sandbox",
            permissionPromptTool = "Rejected by the permission prompt tool",
            hook = "Rejected",
            unknownType = "Rejected",
        }) do
            it("labels " .. reason_type, function()
                assert.equal(label, ClaudeUtils.denial_line(reason_type, nil))
                assert.equal(
                    label .. ": why",
                    ClaudeUtils.denial_line(reason_type, "why")
                )
            end)
        end

        it("labels a missing type", function()
            assert.equal("Rejected", ClaudeUtils.denial_line(nil, nil))
        end)

        it("ignores an empty reason", function()
            assert.equal(
                "Rejected by the permission mode",
                ClaudeUtils.denial_line("mode", "")
            )
        end)

        it("joins a multi-line reason with spaces", function()
            assert.equal(
                "Rejected by the auto-mode classifier: [Secret-Store Writes] writes a key",
                ClaudeUtils.denial_line(
                    "classifier",
                    "[Secret-Store Writes]\nwrites a key"
                )
            )
        end)
    end)

    describe("non_execution_line", function()
        for kind, line in pairs({
            ["permission-rule"] = "Rejected",
            ["automode-blocked"] = "Rejected by the auto-mode classifier",
            ["automode-unavailable"] = "Rejected: the auto-mode classifier is unavailable",
            ["automode-parsing-error"] = "Rejected: the auto-mode classifier gave no verdict",
        }) do
            it("gives a line for " .. kind, function()
                assert.equal(line, ClaudeUtils.non_execution_line(kind))
            end)
        end

        for _, kind in ipairs({
            "user-rejected",
            "interrupted",
            "cancelled",
            "unknown-kind",
        }) do
            it("gives nil for " .. kind, function()
                assert.is_nil(ClaudeUtils.non_execution_line(kind))
            end)
        end

        it("gives nil for no kind", function()
            assert.is_nil(ClaudeUtils.non_execution_line(nil))
        end)
    end)

    describe("is_denial_response", function()
        it("accepts the bridge's denial shape", function()
            assert.is_true(ClaudeUtils.is_denial_response({
                decisionReasonType = "rule",
                message = "Permission to use Bash has been denied.",
            }))
        end)

        it("accepts the shape with an extra key", function()
            assert.is_true(ClaudeUtils.is_denial_response({
                decisionReasonType = "classifier",
                decisionReason = "[Secret-Store Writes]",
                message = "…",
                extra = true,
            }))
        end)

        it("rejects a message alone, an empty table and nil", function()
            assert.is_false(ClaudeUtils.is_denial_response({ message = "m" }))
            assert.is_false(ClaudeUtils.is_denial_response({}))
            assert.is_false(ClaudeUtils.is_denial_response(nil))
        end)
    end)
end)
