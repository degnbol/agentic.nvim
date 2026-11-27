--- @diagnostic disable: invisible, assign-type-mismatch, missing-fields, return-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Deferred = require("tests.helpers.deferred")
local FileSystem = require("agentic.utils.file_system")

describe("agentic.acp.adapters.OpenCodeACPAdapter", function()
    --- @type table
    local OpenCodeACPAdapter

    before_each(function()
        OpenCodeACPAdapter =
            require("agentic.acp.adapters.opencode_acp_adapter")
    end)

    local ABS = "/abs/project/a.txt"

    --- @param handler "on_tool_call"|"on_tool_call_update"
    --- @return table adapter
    --- @return TestSpy sub_spy
    local function adapter_with(handler)
        local sub_spy = spy.new(function() end)
        local adapter = setmetatable({
            _children = {},
            subscribers = { ["sess-1"] = { [handler] = sub_spy } },
        }, { __index = OpenCodeACPAdapter })
        return adapter, sub_spy
    end

    describe("__handle_tool_call", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        --- @param update table
        --- @return table message
        local function handle(update)
            local adapter, sub_spy = adapter_with("on_tool_call")
            adapter:__handle_tool_call("sess-1", update)
            deferred.drain()
            assert.spy(sub_spy).was.called(1)
            return sub_spy.calls[1][1]
        end

        it("renders a replayed subagent from its input", function()
            local msg = handle({
                toolCallId = "tc-1",
                name = "subagent",
                title = "subagent",
                kind = "think",
                status = "pending",
                rawInput = {
                    agent = "general",
                    description = "d",
                    prompt = "p",
                },
            })

            assert.equal("SubAgent", msg.kind)
            assert.equal("general: d", msg.argument)
            assert.same({ "p" }, msg.body)
        end)

        it("takes a replayed read's path from its location", function()
            local msg = handle({
                toolCallId = "tc-2",
                name = "read",
                title = "read",
                kind = "read",
                status = "pending",
                rawInput = { path = "a.txt" },
                locations = { { path = ABS } },
            })

            assert.equal(FileSystem.to_smart_path(ABS), msg.argument)
        end)

        it("keeps a live shell call's head off its cwd", function()
            local msg = handle({
                toolCallId = "tc-shell",
                name = "shell",
                title = "shell",
                kind = "execute",
                status = "pending",
                rawInput = { cwd = "/abs/project" },
                locations = { { path = "/abs/project" } },
            })

            assert.equal("shell", msg.argument)
        end)

        it("formats a child grep by its name", function()
            local msg = handle({
                toolCallId = "tc-3",
                name = "grep",
                title = "child: grep",
                kind = "search",
                status = "pending",
                rawInput = { pattern = "foo" },
            })

            assert.equal('rg "foo"', msg.argument)
            assert.equal("foo", msg.search_pattern)
        end)

        it("re-kinds a skill by its name", function()
            local msg = handle({
                toolCallId = "tc-4",
                name = "skill",
                title = "child: skill",
                kind = "other",
                status = "pending",
                rawInput = {},
            })

            assert.equal("Skill", msg.kind)
        end)
    end)

    describe("__handle_tool_call_update", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        it("handles completed SubAgent update", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
                _children = {},
                subscribers = {
                    ["sess-1"] = {
                        on_tool_call_update = sub_spy,
                    },
                },
            }, { __index = OpenCodeACPAdapter })

            adapter:__handle_tool_call_update("sess-1", {
                toolCallId = "tc-task-1",
                status = "completed",
                kind = "think",
                content = {
                    {
                        type = "content",
                        content = {
                            type = "text",
                            text = "SubAgent completed.\nFound 5 references.",
                        },
                    },
                },
            })

            deferred.drain()

            assert.spy(sub_spy).was.called(1)

            local msg = sub_spy.calls[1][1]
            assert.equal("SubAgent", msg.kind)
            assert.equal("completed", msg.status)
            assert.equal("tc-task-1", msg.tool_call_id)
            assert.same(
                { "SubAgent completed.", "Found 5 references." },
                msg.body
            )
        end)

        it("handles failed SubAgent with a multi-line body", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
                _children = {},
                subscribers = {
                    ["sess-1"] = {
                        on_tool_call_update = sub_spy,
                    },
                },
            }, { __index = OpenCodeACPAdapter })

            adapter:__handle_tool_call_update("sess-1", {
                toolCallId = "tc-task-2",
                status = "failed",
                kind = "think",
                title = "subagent",
                rawInput = {
                    agent = "explore",
                    description = "search codebase",
                    prompt = "Find X",
                },
                content = {
                    {
                        type = "content",
                        content = {
                            type = "text",
                            text = "task_id: sess_abc (for resuming)\n\n<task_result>\nFound matching patterns in 3 files.\n</task_result>",
                        },
                    },
                },
            })

            deferred.drain()

            assert.spy(sub_spy).was.called(1)

            local msg = sub_spy.calls[1][1]
            assert.equal("SubAgent", msg.kind)
            assert.equal("tc-task-2", msg.tool_call_id)
            assert.same({
                "task_id: sess_abc (for resuming)",
                "",
                "<task_result>",
                "Found matching patterns in 3 files.",
                "</task_result>",
            }, msg.body)
        end)

        it("skips update when status is nil", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
                _children = {},
                subscribers = {
                    ["sess-1"] = {
                        on_tool_call_update = sub_spy,
                    },
                },
            }, { __index = OpenCodeACPAdapter })

            adapter:__handle_tool_call_update("sess-1", {
                toolCallId = "tc-task-3",
                kind = "think",
                rawInput = { agent = "general" },
            })

            -- The nil-status early return schedules no subscriber call. Drain
            -- so that a queued call would show.
            deferred.drain()
            assert.spy(sub_spy).was.called(0)
        end)

        it("relabels in_progress to pending for SubAgent", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
                _children = {},
                subscribers = {
                    ["sess-1"] = {
                        on_tool_call_update = sub_spy,
                    },
                },
            }, { __index = OpenCodeACPAdapter })

            adapter:__handle_tool_call_update("sess-1", {
                toolCallId = "tc-task-4",
                status = "in_progress",
                kind = "think",
                title = "subagent",
                rawInput = {
                    agent = "general",
                    description = "test task",
                    prompt = "p",
                },
            })

            deferred.drain()

            assert.spy(sub_spy).was.called(1)

            local msg = sub_spy.calls[1][1]
            assert.equal("SubAgent", msg.kind)
            assert.equal("pending", msg.status)
            assert.equal("general: test task", msg.argument)
            assert.same({ "p" }, msg.body)
        end)

        --- @param update table
        --- @return table message
        local function handle(update)
            local adapter, sub_spy = adapter_with("on_tool_call_update")
            adapter:__handle_tool_call_update("sess-1", update)
            deferred.drain()
            assert.spy(sub_spy).was.called(1)
            return sub_spy.calls[1][1]
        end

        it("takes an in-progress edit's path from its location", function()
            local msg = handle({
                toolCallId = "tc-edit",
                status = "in_progress",
                kind = "edit",
                title = "edit",
                rawInput = { path = "a.txt", oldString = "a", newString = "b" },
                locations = { { path = ABS } },
            })

            assert.equal(FileSystem.to_smart_path(ABS), msg.argument)
            assert.same({ old = { "a" }, new = { "b" }, all = false }, msg.diff)
        end)

        it("shows an in-progress skill's id", function()
            local msg = handle({
                toolCallId = "tc-skill",
                status = "in_progress",
                kind = "other",
                title = "skill",
                rawInput = { id = "x" },
            })

            assert.equal("x", msg.argument)
        end)

        it("shows a failed call's error, not its title", function()
            local msg = handle({
                toolCallId = "tc-mcp",
                status = "failed",
                kind = "other",
                title = "mcp_tool",
                rawInput = { name = "n" },
                content = {
                    {
                        type = "content",
                        content = { type = "text", text = "boom" },
                    },
                },
            })

            assert.same({ "boom" }, msg.body)
        end)

        --- @param status string
        --- @param err string
        --- @return table message
        local function shell_end(status, err)
            return handle({
                toolCallId = "tc-shell",
                status = status,
                kind = "execute",
                title = "shell",
                rawOutput = { error = err, metadata = {} },
                content = {
                    {
                        type = "content",
                        content = { type = "text", text = err },
                    },
                },
            })
        end

        it("rejects a call the user declined", function()
            local msg = shell_end("failed", "The user declined this tool call")

            assert.equal("Rejected", msg.rejection)
            assert.is_nil(msg.body)
        end)

        it("rejects a command the shell scanner refused", function()
            local msg = shell_end(
                "failed",
                "Portable shell scanner cannot analyze command: unterminated-quote"
            )

            assert.equal(
                "Rejected: Portable shell scanner cannot analyze command: unterminated-quote",
                msg.rejection
            )
            assert.is_nil(msg.body)
        end)

        it("keeps a failed call with another error as run", function()
            local msg = shell_end("failed", "Tool execution aborted")

            assert.is_nil(msg.rejection)
            assert.same({ "Tool execution aborted" }, msg.body)
        end)

        it("rejects no completed call", function()
            local msg =
                shell_end("completed", "The user declined this tool call")

            assert.is_nil(msg.rejection)
        end)
    end)

    describe("unattended_env", function()
        local ASK = { action = "*", resource = "*", effect = "ask" }

        --- @type string|nil
        local saved_env

        before_each(function()
            saved_env = vim.env.OPENCODE_CONFIG_CONTENT
            vim.env.OPENCODE_CONFIG_CONTENT = nil
        end)

        after_each(function()
            vim.env.OPENCODE_CONFIG_CONTENT = saved_env
        end)

        --- @param env table<string, string>
        --- @return table config Decoded `OPENCODE_CONFIG_CONTENT`
        local function config_of(env)
            local result, err = OpenCodeACPAdapter:unattended_env(env)
            assert.is_nil(err)
            return vim.json.decode(result.OPENCODE_CONFIG_CONTENT)
        end

        it("asks for every call without a base config", function()
            assert.same({ permissions = { ASK } }, config_of({}))
        end)

        it("appends the rule to the base's rules and keeps its keys", function()
            local allow = { action = "shell", resource = "*", effect = "allow" }
            local config = config_of({
                OPENCODE_CONFIG_CONTENT = vim.json.encode({
                    model = "a/b",
                    permissions = { allow },
                }),
            })

            assert.same({ model = "a/b", permissions = { allow, ASK } }, config)
        end)

        it("reads the base from the editor's env", function()
            vim.env.OPENCODE_CONFIG_CONTENT = '{"model":"a/b"}'

            assert.same({ model = "a/b", permissions = { ASK } }, config_of({}))
        end)

        it("rejects a base that is not a JSON object", function()
            for _, base in ipairs({
                "{",
                "[]",
                '"x"',
                "1",
                "null",
                '{"permissions":{}}',
                '{"permissions":{"edit":"ask"}}',
            }) do
                local result, err = OpenCodeACPAdapter:unattended_env({
                    OPENCODE_CONFIG_CONTENT = base,
                })
                assert.is_nil(result)
                assert.truthy(err:find("OPENCODE_CONFIG_CONTENT", 1, true))
            end
        end)
    end)
end)
