--- @diagnostic disable: undefined-field
local assert = require("tests.helpers.assert")

local ClaudeV2Codec = require("agentic.acp.adapters.claude_v2_codec")

local NIL = vim.NIL

describe("agentic.acp.ClaudeV2Codec", function()
    --- @type agentic.acp.ClaudeV2Codec.State
    local state

    before_each(function()
        state = ClaudeV2Codec.state()
    end)

    describe("decode_update", function()
        it("decodes a call's first report as tool_call", function()
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                name = "Read",
                title = "Read",
                kind = "read",
                status = "pending",
                _meta = { claudeCode = { parentToolUseId = "p" } },
            })
            assert.same({
                {
                    sessionUpdate = "tool_call",
                    toolCallId = "t1",
                    title = "Read",
                    kind = "read",
                    status = "pending",
                    _meta = {
                        claudeCode = {
                            parentToolUseId = "p",
                            toolName = "Read",
                        },
                    },
                },
            }, updates)
        end)

        it("keeps later reports tool_call_update", function()
            ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                name = "Bash",
            })
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "completed",
            })
            assert.same({
                {
                    sessionUpdate = "tool_call_update",
                    toolCallId = "t1",
                    status = "completed",
                    _meta = { claudeCode = { toolName = "Bash" } },
                },
            }, updates)
        end)

        it("merges a _meta patch by key, deleting null keys", function()
            ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                _meta = { a = 1, b = 2 },
            })
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "in_progress",
                _meta = { a = NIL, c = 3 },
            })
            assert.same({ b = 2, c = 3 }, updates[1]._meta)
        end)

        it("clears every _meta key on _meta = null", function()
            ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "pending",
                _meta = { a = 1 },
            })
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "completed",
                _meta = NIL,
            })
            assert.is_nil(updates[1]._meta)
        end)

        it("keeps the tool name across a claudeCode patch", function()
            ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                name = "Edit",
                _meta = { claudeCode = { a = 1 } },
            })
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "completed",
                _meta = { claudeCode = { toolResponse = { x = 1 } } },
            })
            assert.same(
                { toolResponse = { x = 1 }, toolName = "Edit" },
                updates[1]._meta.claudeCode
            )
        end)

        it("decodes a replayed start and its patch as one tool_call", function()
            local start = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                name = "Read",
                status = "completed",
                rawInput = { file_path = "/a" },
                _meta = NIL,
            })
            assert.same({}, start)
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                _meta = { claudeCode = { parentToolUseId = "p" } },
            })
            assert.same({
                {
                    sessionUpdate = "tool_call",
                    toolCallId = "t1",
                    status = "completed",
                    rawInput = { file_path = "/a" },
                    _meta = {
                        claudeCode = {
                            parentToolUseId = "p",
                            toolName = "Read",
                        },
                    },
                },
            }, updates)
        end)

        it("flushes a held start before any other update", function()
            ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "completed",
                _meta = NIL,
            })
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "state_update",
                state = "idle",
            })
            assert.same({
                {
                    sessionUpdate = "tool_call",
                    toolCallId = "t1",
                    status = "completed",
                },
                { sessionUpdate = "state_update", state = "idle" },
            }, updates)
        end)

        it("starts a call again after a resume, keeping its _meta", function()
            ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                name = "Read",
                _meta = { a = 1 },
            })
            ClaudeV2Codec.encode_request(
                state,
                "session/load",
                { sessionId = "s" }
            )
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "completed",
            })
            assert.same({
                {
                    sessionUpdate = "tool_call",
                    toolCallId = "t1",
                    status = "completed",
                    _meta = { a = 1, claudeCode = { toolName = "Read" } },
                },
            }, updates)
        end)

        it("decodes terminal output and exit without storing them", function()
            ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                name = "Bash",
            })
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "terminal_update",
                terminalId = "t1",
                output = { data = vim.base64.encode("hi\n") },
                exitStatus = { exitCode = 0 },
            })
            assert.same({
                {
                    sessionUpdate = "tool_call_update",
                    toolCallId = "t1",
                    _meta = {
                        terminal_output = { terminal_id = "t1", data = "hi\n" },
                        terminal_exit = { terminal_id = "t1", exit_code = 0 },
                        claudeCode = { toolName = "Bash" },
                    },
                },
            }, updates)
            local later = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "completed",
            })
            assert.same({ claudeCode = { toolName = "Bash" } }, later[1]._meta)
        end)

        it("drops a terminal_update without output or exit", function()
            assert.same(
                {},
                ClaudeV2Codec.decode_update(state, {
                    sessionUpdate = "terminal_update",
                    terminalId = "t1",
                    command = "ls",
                })
            )
            assert.same(
                {},
                ClaudeV2Codec.decode_update(state, {
                    sessionUpdate = "terminal_output_chunk",
                    terminalId = "t1",
                    data = "aGk=",
                })
            )
        end)

        it("decodes a diff patch into one v1 diff per hunk", function()
            local patch = table.concat({
                "diff --git /a.lua /a.lua",
                "--- /a.lua",
                "+++ /a.lua",
                "@@ -1,2 +1,2 @@",
                " x",
                "-y",
                "+z",
                "@@ -9 +9,0 @@",
                "-gone",
                "",
            }, "\n")
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                content = {
                    {
                        type = "content",
                        content = { type = "text", text = "a" },
                    },
                    {
                        type = "diff",
                        changes = { { operation = "modify", path = "/a.lua" } },
                        patch = { format = "git_patch", text = patch },
                    },
                },
            })
            assert.same({
                { type = "content", content = { type = "text", text = "a" } },
                {
                    type = "diff",
                    path = "/a.lua",
                    oldText = "x\ny",
                    newText = "x\nz",
                },
                {
                    type = "diff",
                    path = "/a.lua",
                    oldText = "gone",
                    newText = "",
                },
            }, updates[1].content)
        end)

        it("gives a created file's diff a null old side", function()
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                content = {
                    {
                        type = "diff",
                        changes = { { operation = "add", path = "/n" } },
                        patch = {
                            format = "git_patch",
                            text = "--- /dev/null\n+++ /n\n@@ -0,0 +1 @@\n+new\n",
                        },
                    },
                },
            })
            assert.same({
                {
                    type = "diff",
                    path = "/n",
                    oldText = NIL,
                    newText = "new",
                },
            }, updates[1].content)
        end)

        it("drops a diff without a patch", function()
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                content = {
                    {
                        type = "diff",
                        changes = { { operation = "modify", path = "/a" } },
                    },
                },
            })
            assert.same({}, updates[1].content)
        end)

        it("decodes an items plan and a removed plan", function()
            local entries = { { content = "a", status = "pending" } }
            assert.same(
                { { sessionUpdate = "plan", entries = entries } },
                ClaudeV2Codec.decode_update(state, {
                    sessionUpdate = "plan_update",
                    plan = {
                        type = "items",
                        planId = "plan",
                        entries = entries,
                    },
                })
            )
            assert.same(
                { { sessionUpdate = "plan", entries = {} } },
                ClaudeV2Codec.decode_update(state, {
                    sessionUpdate = "plan_removed",
                    planId = "plan",
                })
            )
            assert.same(
                {},
                ClaudeV2Codec.decode_update(state, {
                    sessionUpdate = "plan_update",
                    plan = { type = "markdown", planId = "p", markdown = "x" },
                })
            )
        end)

        it("renames config option ids and degrades boolean options", function()
            local updates = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "config_option_update",
                configOptions = {
                    {
                        configId = "model",
                        type = "select",
                        currentValue = "a",
                        options = {
                            {
                                groupId = "g",
                                name = "G",
                                options = { { value = "a" } },
                            },
                        },
                    },
                    {
                        configId = "fast_mode",
                        type = "boolean",
                        currentValue = true,
                    },
                },
            })
            assert.same({
                {
                    sessionUpdate = "config_option_update",
                    configOptions = {
                        {
                            id = "model",
                            type = "select",
                            currentValue = "a",
                            options = {
                                {
                                    group = "g",
                                    name = "G",
                                    options = { { value = "a" } },
                                },
                            },
                        },
                        {
                            id = "fast_mode",
                            type = "select",
                            currentValue = "on",
                            options = {
                                { value = "on", name = "On" },
                                { value = "off", name = "Off" },
                            },
                        },
                    },
                },
            }, updates)
        end)

        it("drops the empty messages that clear a replay", function()
            for _, kind in ipairs({
                "user_message",
                "agent_message",
                "agent_thought",
            }) do
                assert.same(
                    {},
                    ClaudeV2Codec.decode_update(state, {
                        sessionUpdate = kind,
                        messageId = "m",
                        content = {},
                    })
                )
            end
            local message = {
                sessionUpdate = "user_message",
                messageId = "m",
                content = { { type = "text", text = "hi" } },
            }
            assert.same(
                { message },
                ClaudeV2Codec.decode_update(state, message)
            )
        end)
    end)

    describe("decode_permission", function()
        it("takes the subject's tool call and merges its _meta", function()
            ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                name = "Bash",
                _meta = { a = 1 },
            })
            local options =
                { { optionId = "allow", kind = "allow_once", name = "Allow" } }
            local request = ClaudeV2Codec.decode_permission(state, {
                sessionId = "s",
                title = "Run ls?",
                subject = {
                    type = "tool_call",
                    toolCall = {
                        toolCallId = "t1",
                        title = "ls",
                        _meta = { a = 1, b = 2 },
                    },
                },
                options = options,
            })
            assert.same({
                sessionId = "s",
                toolCall = {
                    toolCallId = "t1",
                    title = "ls",
                    _meta = { a = 1, b = 2, claudeCode = { toolName = "Bash" } },
                },
                options = options,
            }, request)
            local later = ClaudeV2Codec.decode_update(state, {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                status = "completed",
            })
            assert.same(2, later[1]._meta.b)
        end)

        it("titles a tool call without one with the request's title", function()
            local request = ClaudeV2Codec.decode_permission(state, {
                sessionId = "s",
                title = "Run ls?",
                subject = {
                    type = "tool_call",
                    toolCall = { toolCallId = "t1" },
                },
                options = {},
            })
            assert.equal("Run ls?", request.toolCall.title)
        end)
    end)

    describe("encode_request", function()
        it("encodes session/load as a session/resume with a replay", function()
            local method, params = ClaudeV2Codec.encode_request(
                state,
                "session/load",
                { sessionId = "s", cwd = "/c", mcpServers = {} }
            )
            assert.equal("session/resume", method)
            assert.same({
                sessionId = "s",
                cwd = "/c",
                mcpServers = {},
                replayFrom = { type = "start" },
            }, params)
        end)

        it("tags a config value as an id", function()
            local _, params = ClaudeV2Codec.encode_request(
                state,
                "session/set_config_option",
                { sessionId = "s", configId = "fast", value = "on" }
            )
            assert.same({
                sessionId = "s",
                configId = "fast",
                type = "id",
                value = "on",
            }, params)
        end)

        it("encodes authenticate as auth/login", function()
            local method, params = ClaudeV2Codec.encode_request(
                state,
                "authenticate",
                { methodId = "m" }
            )
            assert.equal("auth/login", method)
            assert.same({ methodId = "m" }, params)
        end)

        it("renames initialize fields and drops what v2 has not", function()
            local method, params =
                ClaudeV2Codec.encode_request(state, "initialize", {
                    protocolVersion = 2,
                    clientInfo = { name = "n", version = "1" },
                    clientCapabilities = {
                        fs = { readTextFile = false, writeTextFile = false },
                        terminal = false,
                        auth = { terminal = true },
                        _meta = { x = true },
                        subagents = vim.empty_dict(),
                    },
                })
            assert.equal("initialize", method)
            assert.same({
                protocolVersion = 2,
                info = { name = "n", version = "1" },
                capabilities = {
                    auth = { terminal = {} },
                    _meta = { x = true },
                },
            }, params)
        end)

        it("passes other requests as they are", function()
            local params = { sessionId = "s", prompt = {} }
            local method, encoded =
                ClaudeV2Codec.encode_request(state, "session/prompt", params)
            assert.equal("session/prompt", method)
            assert.same(params, encoded)
        end)
    end)

    describe("on a recorded claude-agent-acp turn", function()
        --- Decoded session updates and permission requests of the fixture.
        --- @return table[] updates
        --- @return agentic.acp.RequestPermission[] permissions
        local function decode_fixture()
            local updates, permissions = {}, {}
            for line in io.lines("tests/fixtures/acp_v2_turn.jsonl") do
                local message = vim.json.decode(line)
                if message.method == "session/update" then
                    vim.list_extend(
                        updates,
                        ClaudeV2Codec.decode_update(
                            state,
                            message.params.update
                        )
                    )
                else
                    table.insert(
                        permissions,
                        ClaudeV2Codec.decode_permission(state, message.params)
                    )
                end
            end
            return updates, permissions
        end

        it("starts each call with a tool_call that names its tool", function()
            local updates = decode_fixture()
            local names = {}
            for _, update in ipairs(updates) do
                if update.sessionUpdate == "tool_call" then
                    table.insert(names, update._meta.claudeCode.toolName)
                end
            end
            assert.same({ "Read", "Edit", "Bash" }, names)
        end)

        it(
            "decodes the Edit's diff in its report and its permission",
            function()
                local updates, permissions = decode_fixture()
                local diff = { oldText = "alpha line", newText = "beta line" }
                local function texts(content)
                    local item = content[1]
                    return { oldText = item.oldText, newText = item.newText }
                end
                local reported
                for _, update in ipairs(updates) do
                    if
                        update.content
                        and update.content[1]
                        and update.content[1].type == "diff"
                    then
                        reported = texts(update.content)
                    end
                end
                assert.same(diff, reported)
                assert.same(diff, texts(permissions[1].toolCall.content))
            end
        )

        it("decodes the background command's output and end", function()
            local updates = decode_fixture()
            local output, ended = nil, false
            for _, update in ipairs(updates) do
                local meta = update._meta or {}
                output = meta.terminal_output and meta.terminal_output.data
                    or output
                ended = ended or meta.terminal_exit ~= nil
            end
            assert.truthy(output:find("running in background", 1, true))
            assert.is_true(ended)
        end)
    end)

    describe("decode_result", function()
        it("decodes an initialize result into v1 capabilities", function()
            local result = ClaudeV2Codec.decode_result("initialize", {
                protocolVersion = 2,
                info = { name = "claude", version = "0.97.0" },
                capabilities = {
                    session = {
                        prompt = { image = {}, embeddedContext = {} },
                        fork = {},
                    },
                    _meta = { y = 1 },
                },
                authMethods = {
                    { methodId = "a", name = "A", type = "agent" },
                    {
                        methodId = "t",
                        name = "T",
                        type = "terminal",
                        args = { "--login" },
                        env = { { name = "K", value = "V" } },
                    },
                },
            })
            assert.same({
                protocolVersion = 2,
                agentInfo = { name = "claude", version = "0.97.0" },
                agentCapabilities = {
                    loadSession = true,
                    promptCapabilities = {
                        image = true,
                        audio = false,
                        embeddedContext = true,
                    },
                    sessionCapabilities = { close = {}, fork = {} },
                    _meta = { y = 1 },
                },
                authMethods = {
                    { id = "a", name = "A", type = "agent" },
                    {
                        id = "t",
                        name = "T",
                        type = "terminal",
                        args = { "--login" },
                        env = { K = "V" },
                    },
                },
            }, result)
        end)

        it(
            "decodes a session result's config options and keeps its commands",
            function()
                local commands = { { name = "review", description = "d" } }
                local result = ClaudeV2Codec.decode_result("session/resume", {
                    configOptions = {
                        {
                            configId = "mode",
                            type = "select",
                            currentValue = "x",
                            options = {},
                        },
                    },
                    availableCommands = commands,
                })
                assert.same({
                    configOptions = {
                        {
                            id = "mode",
                            type = "select",
                            currentValue = "x",
                            options = {},
                        },
                    },
                    availableCommands = commands,
                }, result)
            end
        )
    end)
end)
