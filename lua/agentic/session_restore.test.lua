local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("SessionRestore", function()
    --- @type agentic.SessionRestore
    local SessionRestore
    local ChatHistory
    local SessionRegistry
    local Logger
    local Config

    --- @type TestStub
    local chat_history_load_stub
    --- @type TestStub
    local chat_history_list_stub
    --- @type TestStub
    local session_registry_stub
    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local vim_fn_confirm_stub

    local test_sessions = {
        {
            session_id = "session-1",
            title = "First chat",
            timestamp = 1704067200,
        },
        {
            session_id = "session-2",
            title = "Second chat",
            timestamp = 1704153600,
        },
    }

    local mock_history = {
        session_id = "restored-session",
        messages = { { type = "user", text = "Previous chat" } },
    }

    local function create_mock_session(opts)
        opts = opts or {}
        return {
            session_id = opts.session_id or "current-session",
            chat_history = opts.chat_history or { messages = {} },
            agent = {
                cancel_session = spy.new(function() end),
                -- Default to no-load support so tests that want the history
                -- fallback work; tests that want the ACP load path override.
                agent_capabilities = opts.agent_capabilities
                    or { loadSession = false },
            },
            widget = {
                clear = spy.new(function() end),
                show = spy.new(function() end),
                close_empty_non_widget_windows = spy.new(function() end),
            },
            restore_from_history = spy.new(function() end),
            load_acp_session = spy.new(function() end),
        }
    end

    local function setup_list_stub(sessions)
        chat_history_list_stub:invokes(function(callback)
            callback(sessions or test_sessions)
        end)
    end

    local function setup_load_stub(history, err)
        chat_history_load_stub:invokes(function(_sid, callback)
            callback(history, err)
        end)
    end

    local function setup_registry_stub(session)
        session_registry_stub:invokes(function(_tab_id, callback)
            callback(session)
        end)
    end

    local original_loaded = {}
    local niled_modules = {
        "agentic.session_restore",
        "agentic.session_restore_builtin",
        "agentic.ui.chat_history",
        "agentic.session_registry",
        "agentic.utils.logger",
        "agentic.config",
    }

    before_each(function()
        for _, mod in ipairs(niled_modules) do
            original_loaded[mod] = package.loaded[mod]
            package.loaded[mod] = nil
        end

        SessionRestore = require("agentic.session_restore")
        ChatHistory = require("agentic.ui.chat_history")
        SessionRegistry = require("agentic.session_registry")
        Logger = require("agentic.utils.logger")
        Config = require("agentic.config")

        -- Force builtin picker which uses vim.fn.confirm for conflict dialogue
        Config.session_restore = { picker = "builtin" }

        chat_history_load_stub = spy.stub(ChatHistory, "load")
        chat_history_list_stub = spy.stub(ChatHistory, "list_sessions")
        session_registry_stub =
            spy.stub(SessionRegistry, "get_session_for_tab_page")
        logger_notify_stub = spy.stub(Logger, "notify")
        vim_fn_confirm_stub = spy.stub(vim.fn, "confirm")
        vim_fn_confirm_stub:returns(0) -- default: cancel (no choice)
    end)

    after_each(function()
        chat_history_load_stub:revert()
        chat_history_list_stub:revert()
        session_registry_stub:revert()
        logger_notify_stub:revert()
        vim_fn_confirm_stub:revert()

        for _, mod in ipairs(niled_modules) do
            package.loaded[mod] = original_loaded[mod]
        end
    end)

    describe("build_items", function()
        it("formats as date │ title", function()
            local items = SessionRestore.build_items(test_sessions)
            assert.equal(2, #items)
            assert.truthy(items[1].display:match("│ First chat"))
            assert.truthy(items[1].display:match("^%d%d%d%d%-%d%d%-%d%d"))
            assert.equal("session-1", items[1].session_id)
        end)

        it("uses (no title) for missing titles", function()
            --- @diagnostic disable-next-line: missing-fields
            local items = SessionRestore.build_items({ { session_id = "s1" } })
            assert.truthy(items[1].display:match("%(no title%)"))
        end)

        it("passes prompt_count through to items", function()
            local items = SessionRestore.build_items({
                {
                    session_id = "s1",
                    title = "With count",
                    timestamp = 1704067200,
                    prompt_count = 5,
                },
                {
                    session_id = "s2",
                    title = "No count",
                    timestamp = 1704067200,
                },
            })
            assert.equal(5, items[1].prompt_count)
            assert.is_nil(items[2].prompt_count)
        end)

        it("strips newlines from multi-line titles", function()
            local items = SessionRestore.build_items({
                {
                    session_id = "s1",
                    title = "First line\nSecond line\nThird",
                    timestamp = 1704067200,
                },
            })
            assert.is_nil(items[1].display:find("\n"))
            assert.truthy(items[1].display:match("│ First line"))
        end)
    end)

    --- @diagnostic disable: missing-fields
    describe("format_preview", function()
        it("formats user messages with heading", function()
            local lines = SessionRestore.format_preview({
                { type = "user", text = "Hello world" },
            })
            assert.truthy(vim.tbl_contains(lines, "## You"))
            assert.truthy(vim.tbl_contains(lines, "Hello world"))
        end)

        it("formats agent messages with heading", function()
            local lines = SessionRestore.format_preview({
                { type = "agent", text = "Response text" },
            })
            assert.truthy(vim.tbl_contains(lines, "## Agent"))
            assert.truthy(vim.tbl_contains(lines, "Response text"))
        end)

        it("truncates long thought blocks", function()
            local long_thought =
                table.concat(vim.fn["repeat"]({ "line" }, 10), "\n")
            local lines = SessionRestore.format_preview({
                { type = "thought", text = long_thought },
            })
            local more_line = vim.tbl_filter(function(l)
                return l:match("more lines")
            end, lines)
            assert.equal(1, #more_line)
        end)

        it("shows tool call with status icon", function()
            local lines = SessionRestore.format_preview({
                {
                    type = "tool_call",
                    kind = "edit",
                    argument = "file.lua",
                    status = "completed",
                },
            })
            local tool_line = vim.tbl_filter(function(l)
                return l:match("edit") and l:match("file.lua")
            end, lines)
            assert.equal(1, #tool_line)
            assert.truthy(tool_line[1]:match("✔"))
        end)

        it("produces no lines with embedded newlines", function()
            local lines = SessionRestore.format_preview({
                { type = "user", text = "line1\nline2\nline3" },
                { type = "agent", text = "resp1\nresp2" },
                {
                    type = "tool_call",
                    kind = "edit",
                    argument = "old\nnew",
                    status = "completed",
                },
            })
            for _, line in ipairs(lines) do
                assert.is_nil(line:find("\n"))
            end
        end)
    end)

    describe("show_picker", function()
        it("notifies and skips picker when no sessions exist", function()
            setup_list_stub({})

            SessionRestore.show_picker(1, nil)

            assert.spy(logger_notify_stub).was.called(1)
            assert.equal(
                "No saved sessions found",
                logger_notify_stub.calls[1][1]
            )
            assert.equal(vim.log.levels.INFO, logger_notify_stub.calls[1][2])
        end)
    end)

    describe("restore without conflict (via builtin picker stub)", function()
        -- The builtin picker creates floating windows, so we stub it
        -- to directly call on_select
        local builtin_show_stub

        before_each(function()
            package.loaded["agentic.session_restore_builtin"] = nil
            local builtin = require("agentic.session_restore_builtin")
            builtin_show_stub = spy.stub(builtin, "show")
        end)

        after_each(function()
            builtin_show_stub:revert()
        end)

        it("restores directly with reuse_session=true", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_history)
            setup_registry_stub(mock_session)

            -- Stub builtin.show to immediately call on_select
            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)

            SessionRestore.show_picker(1, nil)

            assert.spy(mock_session.agent.cancel_session).was.called(0)
            assert.spy(mock_session.widget.clear).was.called(0)
            assert.spy(mock_session.restore_from_history).was.called(1)

            local restore_call = mock_session.restore_from_history.calls[1]
            assert.equal(mock_history, restore_call[2])
            assert.is_true(restore_call[3].reuse_session)
            assert.spy(mock_session.widget.show).was.called(1)
        end)
    end)

    describe("restore with conflict", function()
        local builtin_show_stub

        before_each(function()
            package.loaded["agentic.session_restore_builtin"] = nil
            local builtin = require("agentic.session_restore_builtin")
            builtin_show_stub = spy.stub(builtin, "show")
        end)

        after_each(function()
            builtin_show_stub:revert()
        end)

        local function session_with_messages()
            return create_mock_session({
                chat_history = { messages = { { type = "user" } } },
            })
        end

        it("prompts user when current session has messages", function()
            local mock_session = session_with_messages()
            setup_list_stub()

            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)

            SessionRestore.show_picker(
                1,
                mock_session --[[@as agentic.SessionManager]]
            )

            -- Conflict dialogue via vim.fn.confirm
            assert.spy(vim_fn_confirm_stub).was.called(1)
            local prompt = vim_fn_confirm_stub.calls[1][1]
            assert.truthy(prompt:match("messages"))
        end)

        it("does nothing when user dismisses conflict prompt", function()
            local mock_session = session_with_messages()
            setup_list_stub()
            -- confirm returns 0 on cancel/dismiss (default from stub)

            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)

            SessionRestore.show_picker(
                1,
                mock_session --[[@as agentic.SessionManager]]
            )

            assert.spy(chat_history_load_stub).was.called(0)
        end)

        it(
            "clears session and restores with reuse_session=false when 'Restore here' chosen",
            function()
                local mock_session = session_with_messages()
                setup_list_stub()
                setup_load_stub(mock_history)
                setup_registry_stub(mock_session)
                vim_fn_confirm_stub:returns(1) -- "Restore here"

                builtin_show_stub:invokes(function(picker_items, on_select)
                    on_select(picker_items[1])
                end)

                SessionRestore.show_picker(
                    1,
                    mock_session --[[@as agentic.SessionManager]]
                )

                assert.spy(mock_session.agent.cancel_session).was.called(1)
                assert.spy(mock_session.widget.clear).was.called(1)

                local restore_call = mock_session.restore_from_history.calls[1]
                assert.is_false(restore_call[3].reuse_session)
            end
        )
    end)

    describe("load failures", function()
        local builtin_show_stub

        before_each(function()
            package.loaded["agentic.session_restore_builtin"] = nil
            local builtin = require("agentic.session_restore_builtin")
            builtin_show_stub = spy.stub(builtin, "show")
            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)
        end)

        after_each(function()
            builtin_show_stub:revert()
        end)

        it("shows warning on load error", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(nil, "File not found")
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1, nil)

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("File not found")
            )
            assert.equal(vim.log.levels.WARN, logger_notify_stub.calls[1][2])
        end)

        it("shows warning on nil history without error", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(nil, nil)
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1, nil)

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(logger_notify_stub.calls[1][1]:match("unknown error"))
        end)
    end)

    describe("restore via load_acp_session", function()
        local builtin_show_stub

        before_each(function()
            package.loaded["agentic.session_restore_builtin"] = nil
            local builtin = require("agentic.session_restore_builtin")
            builtin_show_stub = spy.stub(builtin, "show")
            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)
        end)

        after_each(function()
            builtin_show_stub:revert()
        end)

        local function session_with_load_support(opts)
            opts = opts or {}
            return create_mock_session(vim.tbl_extend("force", opts, {
                agent_capabilities = { loadSession = true },
            }))
        end

        it("uses load_acp_session when agent supports loadSession", function()
            local mock_session = session_with_load_support()
            setup_list_stub()
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1, nil)

            assert.spy(mock_session.load_acp_session).was.called(1)
            assert.equal("session-1", mock_session.load_acp_session.calls[1][2])
            assert.spy(mock_session.restore_from_history).was.called(0)
            assert.spy(chat_history_load_stub).was.called(0)
            assert.spy(mock_session.widget.show).was.called(1)
        end)

        it(
            "skips manual cancel when using load_acp_session (it cancels internally)",
            function()
                local mock_session = session_with_load_support({
                    chat_history = { messages = { { type = "user" } } },
                })
                setup_list_stub()
                setup_registry_stub(mock_session)

                vim_fn_confirm_stub:returns(1) -- "Restore here"

                SessionRestore.show_picker(
                    1,
                    mock_session --[[@as agentic.SessionManager]]
                )

                assert.spy(mock_session.agent.cancel_session).was.called(0)
                assert.spy(mock_session.widget.clear).was.called(0)
                assert.spy(mock_session.load_acp_session).was.called(1)
            end
        )

        it(
            "falls back to restore_from_history when loadSession not supported",
            function()
                local mock_session = create_mock_session()
                setup_list_stub()
                setup_load_stub(mock_history)
                setup_registry_stub(mock_session)

                SessionRestore.show_picker(1, nil)

                assert.spy(mock_session.load_acp_session).was.called(0)
                assert.spy(mock_session.restore_from_history).was.called(1)
            end
        )

        it("forwards saved model to load_acp_session", function()
            local mock_session = session_with_load_support()
            chat_history_list_stub:invokes(function(callback)
                callback({
                    {
                        session_id = "session-1",
                        title = "With model",
                        timestamp = 1704067200,
                        provider = Config.provider,
                        model = "sonnet-4-6",
                    },
                })
            end)
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1, nil)

            assert.spy(mock_session.load_acp_session).was.called(1)
            assert.equal(
                "sonnet-4-6",
                mock_session.load_acp_session.calls[1][4]
            )
        end)

        it(
            "switches Config.provider and destroys existing session when saved provider differs",
            function()
                local mock_session = session_with_load_support()
                chat_history_list_stub:invokes(function(callback)
                    callback({
                        {
                            session_id = "session-1",
                            title = "Other provider",
                            timestamp = 1704067200,
                            provider = "opencode-acp",
                            model = "minimax",
                        },
                    })
                end)
                setup_registry_stub(mock_session)
                local destroy_stub =
                    spy.stub(SessionRegistry, "destroy_session")
                local original_provider = Config.provider

                SessionRestore.show_picker(1, nil)

                assert.equal("opencode-acp", Config.provider)
                assert.spy(destroy_stub).was.called(1)

                Config.provider = original_provider
                destroy_stub:revert()
            end
        )

        it(
            "warns but keeps current provider for sessions without provider",
            function()
                local mock_session = session_with_load_support()
                setup_list_stub() -- default test_sessions have no provider field
                setup_registry_stub(mock_session)

                SessionRestore.show_picker(1, nil)

                local messages = {}
                for _, call in ipairs(logger_notify_stub.calls) do
                    table.insert(messages, call[1])
                end
                local found = false
                for _, msg in ipairs(messages) do
                    if msg:match("no saved provider") then
                        found = true
                        break
                    end
                end
                assert.is_true(found)
                assert.spy(mock_session.load_acp_session).was.called(1)
            end
        )
    end)

    describe("conflict detection", function()
        local builtin_show_stub

        before_each(function()
            package.loaded["agentic.session_restore_builtin"] = nil
            local builtin = require("agentic.session_restore_builtin")
            builtin_show_stub = spy.stub(builtin, "show")
            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)
        end)

        after_each(function()
            builtin_show_stub:revert()
        end)

        it("detects no conflict when current_session is nil", function()
            setup_list_stub()

            SessionRestore.show_picker(1, nil)

            -- No conflict dialogue
            assert.spy(vim_fn_confirm_stub).was.called(0) -- no conflict dialogue
        end)

        it("detects no conflict when session_id is nil", function()
            local session = {
                session_id = nil,
                chat_history = { messages = { { type = "user" } } },
            }
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            assert.spy(vim_fn_confirm_stub).was.called(0) -- no conflict dialogue
        end)

        it("detects no conflict when chat_history is nil", function()
            local session = { session_id = "current", chat_history = nil }
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            assert.spy(vim_fn_confirm_stub).was.called(0) -- no conflict dialogue
        end)

        it("detects no conflict when messages array is empty", function()
            local session =
                { session_id = "current", chat_history = { messages = {} } }
            setup_list_stub()

            SessionRestore.show_picker(
                1,
                session --[[@as agentic.SessionManager]]
            )

            assert.spy(vim_fn_confirm_stub).was.called(0) -- no conflict dialogue
        end)
    end)

    --- @diagnostic disable: missing-fields
    describe("replay_messages", function()
        it("replays user and agent messages", function()
            local write_message_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    { type = "user", text = "Hello" },
                    { type = "agent", text = "Hi there" },
                }
            )

            assert.equal(2, write_message_spy.call_count)
        end)

        it("replays thought chunks", function()
            local write_message_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    { type = "thought", text = "Thinking..." },
                }
            )

            assert.equal(1, write_chunk_spy.call_count)
        end)

        it("replays tool calls", function()
            local write_message_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t1",
                        kind = "edit",
                        argument = "file.lua",
                        status = "completed",
                    },
                }
            )

            assert.equal(1, write_tool_spy.call_count)
        end)
    end)
end)
