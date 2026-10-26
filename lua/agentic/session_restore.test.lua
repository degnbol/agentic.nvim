local assert = require("tests.helpers.assert")
local Glyphs = require("agentic.glyphs")
local spy = require("tests.helpers.spy")

describe("SessionRestore", function()
    --- @type agentic.SessionRestore
    local SessionRestore
    local ChatHistory
    local SessionRegistry
    local Logger
    local Config

    --- @type TestStub
    local read_json_stub
    --- @type TestStub
    local from_data_stub
    --- @type TestStub
    local chat_history_list_stub
    --- @type TestStub
    local session_registry_stub
    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local vim_fn_confirm_stub
    --- @type TestStub
    local target_win_stub
    --- What `SessionRegistry.target_win()` returns in every case.
    local TARGET_WIN = 4242

    local test_sessions = {
        {
            session_id = "session-1",
            title = "First chat",
            timestamp = 1704067200,
            file_path = "/storage/p/session-1.json",
        },
        {
            session_id = "session-2",
            title = "Second chat",
            timestamp = 1704153600,
            file_path = "/storage/p/session-2.json",
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
                reveal = spy.new(function() end),
            },
            clear_chat = spy.new(function() end),
            permission_manager = { clear = spy.new(function() end) },
            restore_from_history = spy.new(function() end),
            load_acp_session = spy.new(function() end),
        }
    end

    local function setup_list_stub(sessions)
        chat_history_list_stub:invokes(function(_cwd, callback)
            callback(sessions or test_sessions)
        end)
    end

    --- Make the session file read as `history`, unchanged by `from_data`.
    local function setup_load_stub(history, err)
        read_json_stub:invokes(function()
            return history, err
        end)
        from_data_stub:invokes(function(data)
            return data
        end)
    end

    local function setup_registry_stub(session)
        session_registry_stub:returns(session)
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

        read_json_stub =
            spy.stub(require("agentic.utils.file_system"), "read_json")
        from_data_stub = spy.stub(ChatHistory, "from_data")
        setup_load_stub(mock_history)
        chat_history_list_stub = spy.stub(ChatHistory, "list_sessions")
        session_registry_stub = spy.stub(SessionRegistry, "create")
        target_win_stub = spy.stub(SessionRegistry, "target_win")
        target_win_stub:returns(TARGET_WIN)
        logger_notify_stub = spy.stub(Logger, "notify")
        vim_fn_confirm_stub = spy.stub(vim.fn, "confirm")
        vim_fn_confirm_stub:returns(0) -- default: cancel (no choice)
    end)

    after_each(function()
        read_json_stub:revert()
        from_data_stub:revert()
        chat_history_list_stub:revert()
        session_registry_stub:revert()
        target_win_stub:revert()
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

        it("shows a shortened cwd when asked", function()
            local home = vim.uv.os_homedir() --[[@as string]]
            local cases = {
                { home .. "/a/b/c/d", "…/c/d" },
                { home .. "/a/b", "~/a/b" },
                { home, "~" },
                { "/x/y", "/x/y" },
                { home .. "x/y", home .. "x/y" },
            }
            for _, case in ipairs(cases) do
                local items = SessionRestore.build_items({
                    {
                        session_id = "s",
                        title = "t",
                        timestamp = 0,
                        file_path = "/s.json",
                        cwd = case[1],
                    },
                }, { show_cwd = true })
                assert.truthy(
                    vim.endswith(items[1].display, "[" .. case[2] .. "]"),
                    items[1].display
                )
            end
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
                    file_path = "/storage/p/s1.json",
                    prompt_count = 5,
                },
                {
                    session_id = "s2",
                    title = "No count",
                    timestamp = 1704067200,
                    file_path = "/storage/p/s2.json",
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
                    file_path = "/storage/p/s1.json",
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

        it("formats a message row as a heading over its text", function()
            local lines = SessionRestore.format_preview({
                {
                    type = "subagent_event",
                    kind = "received",
                    title = "From map UI",
                    body = { "Found it." },
                },
            })
            assert.same({ "## From map UI", "Found it.", "" }, lines)
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

        it("marks a cancelled tool call as over, not running", function()
            local lines = SessionRestore.format_preview({
                {
                    type = "tool_call",
                    kind = "edit",
                    argument = "file.lua",
                    status = "cancelled",
                },
            })
            local tool_line = vim.tbl_filter(function(l)
                return l:match("edit")
            end, lines)
            assert.equal(1, #tool_line)
            -- The preview reads the same glyph vocabulary as the live footer,
            -- so a cancelled call no longer takes the "…" that means the turn
            -- is still working on it.
            assert.truthy(
                tool_line[1]:find(Config.status_icons.cancelled, 1, true)
            )
            assert.is_nil(tool_line[1]:find("…", 1, true))
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

            SessionRestore.show_picker(
                create_mock_session() --[[@as agentic.SessionManager]]
            )

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

        it("shows a picked session that is already open", function()
            local mock_session = create_mock_session({
                chat_history = { messages = { { type = "user" } } },
            })
            local open_session = create_mock_session()
            local open_stub = spy.stub(SessionRegistry, "session_for_acp_id")
            open_stub:returns(open_session)
            setup_list_stub()
            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)

            SessionRestore.show_picker(
                mock_session --[[@as agentic.SessionManager]]
            )

            assert.equal("session-1", open_stub.calls[1][1])
            assert.spy(open_session.widget.reveal).was.called(1)
            assert.equal(TARGET_WIN, open_session.widget.reveal.calls[1][2])
            assert.spy(vim_fn_confirm_stub).was.called(0)
            assert.spy(session_registry_stub).was.called(0)
            assert.spy(mock_session.restore_from_history).was.called(0)
            assert.spy(mock_session.load_acp_session).was.called(0)
            open_stub:revert()
        end)

        it("restores directly with reuse_session=true", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_history)

            -- Stub builtin.show to immediately call on_select
            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)

            SessionRestore.show_picker(
                mock_session --[[@as agentic.SessionManager]]
            )

            assert.spy(mock_session.agent.cancel_session).was.called(0)
            assert.spy(mock_session.clear_chat).was.called(0)
            assert.spy(mock_session.permission_manager.clear).was.called(0)
            assert.spy(mock_session.restore_from_history).was.called(1)

            local restore_call = mock_session.restore_from_history.calls[1]
            assert.equal(mock_history, restore_call[2])
            assert.is_true(restore_call[3].reuse_session)
            assert.spy(mock_session.widget.reveal).was.called(1)
            assert.equal(TARGET_WIN, mock_session.widget.reveal.calls[1][2])
        end)

        it("reads the item's file", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_history)
            builtin_show_stub:invokes(function(picker_items, on_select)
                on_select(picker_items[1])
            end)

            SessionRestore.show_picker(
                mock_session --[[@as agentic.SessionManager]]
            )

            assert.same(
                { "/storage/p/session-1.json", n = 1 },
                read_json_stub.calls[1]
            )
            assert.spy(mock_session.restore_from_history).was.called(1)
        end)
    end)

    describe("list", function()
        it("lists the project folder of the editor cwd", function()
            setup_list_stub()

            SessionRestore.list("local", function() end)

            assert.equal(vim.fn.getcwd(), chat_history_list_stub.calls[1][1])
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
                mock_session --[[@as agentic.SessionManager]]
            )

            assert.spy(read_json_stub).was.called(0)
        end)

        it(
            "clears session and restores with reuse_session=false when 'Restore here' chosen",
            function()
                local mock_session = session_with_messages()
                setup_list_stub()
                setup_load_stub(mock_history)
                vim_fn_confirm_stub:returns(1) -- "Restore here"

                builtin_show_stub:invokes(function(picker_items, on_select)
                    on_select(picker_items[1])
                end)

                SessionRestore.show_picker(
                    mock_session --[[@as agentic.SessionManager]]
                )

                assert.spy(mock_session.agent.cancel_session).was.called(1)
                assert.spy(mock_session.clear_chat).was.called(1)
                assert.spy(mock_session.permission_manager.clear).was.called(1)

                local restore_call = mock_session.restore_from_history.calls[1]
                assert.is_false(restore_call[3].reuse_session)
            end
        )

        it(
            "restores into a new session when the current one was destroyed",
            function()
                local mock_session = session_with_messages()
                local new_session = create_mock_session()
                setup_list_stub()
                setup_load_stub(mock_history)
                setup_registry_stub(new_session)
                builtin_show_stub:invokes(function(picker_items, on_select)
                    mock_session.destroyed = true
                    on_select(picker_items[1])
                end)

                SessionRestore.show_picker(
                    mock_session --[[@as agentic.SessionManager]]
                )

                assert.spy(vim_fn_confirm_stub).was.called(0)
                assert.spy(mock_session.restore_from_history).was.called(0)
                assert.spy(new_session.restore_from_history).was.called(1)
                assert.is_true(
                    new_session.restore_from_history.calls[1][3].reuse_session
                )
                assert.spy(new_session.widget.reveal).was.called(1)
                assert.equal(TARGET_WIN, new_session.widget.reveal.calls[1][2])
            end
        )

        it(
            "restores into a new session shown in a new tab when 'Open in new tab' chosen",
            function()
                local mock_session = session_with_messages()
                local new_session = create_mock_session()
                local chat = vim.api.nvim_create_buf(false, true)
                new_session.widget.buf_nrs = { chat = chat }
                new_session.widget.show = require("agentic.ui.chat_widget").show
                new_session.widget.show_in = spy.new(function() end)
                setup_list_stub()
                setup_load_stub(mock_history)
                setup_registry_stub(new_session)
                vim_fn_confirm_stub:returns(2)
                builtin_show_stub:invokes(function(picker_items, on_select)
                    on_select(picker_items[1])
                end)
                local tabs_before = #vim.api.nvim_list_tabpages()

                SessionRestore.show_picker(
                    mock_session --[[@as agentic.SessionManager]]
                )

                assert.spy(mock_session.restore_from_history).was.called(0)
                assert.spy(new_session.restore_from_history).was.called(1)
                assert.equal(tabs_before + 1, #vim.api.nvim_list_tabpages())
                assert.same(
                    { chat },
                    vim.tbl_map(
                        vim.api.nvim_win_get_buf,
                        vim.api.nvim_tabpage_list_wins(0)
                    )
                )
                assert.equal(
                    vim.api.nvim_get_current_win(),
                    new_session.widget.show_in.calls[1][2]
                )

                vim.cmd("tabclose")
                vim.api.nvim_buf_delete(chat, { force = true })
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

            SessionRestore.show_picker(
                mock_session --[[@as agentic.SessionManager]]
            )

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("File not found")
            )
            assert.equal(vim.log.levels.WARN, logger_notify_stub.calls[1][2])
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

            SessionRestore.show_picker(
                mock_session --[[@as agentic.SessionManager]]
            )

            assert.spy(mock_session.load_acp_session).was.called(1)
            assert.equal("session-1", mock_session.load_acp_session.calls[1][2])
            assert.spy(mock_session.restore_from_history).was.called(0)
            assert.spy(read_json_stub).was.called(0)
            assert.spy(mock_session.widget.reveal).was.called(1)
            assert.equal(TARGET_WIN, mock_session.widget.reveal.calls[1][2])
        end)

        it(
            "skips manual cancel when using load_acp_session (it cancels internally)",
            function()
                local mock_session = session_with_load_support({
                    chat_history = { messages = { { type = "user" } } },
                })
                setup_list_stub()

                vim_fn_confirm_stub:returns(1) -- "Restore here"

                SessionRestore.show_picker(
                    mock_session --[[@as agentic.SessionManager]]
                )

                assert.spy(mock_session.agent.cancel_session).was.called(0)
                assert.spy(mock_session.clear_chat).was.called(0)
                assert.spy(mock_session.load_acp_session).was.called(1)
            end
        )

        it(
            "falls back to restore_from_history when loadSession not supported",
            function()
                local mock_session = create_mock_session()
                setup_list_stub()
                setup_load_stub(mock_history)

                SessionRestore.show_picker(
                    mock_session --[[@as agentic.SessionManager]]
                )

                assert.spy(mock_session.load_acp_session).was.called(0)
                assert.spy(mock_session.restore_from_history).was.called(1)
            end
        )

        it("forwards saved model to load_acp_session", function()
            local mock_session = session_with_load_support()
            chat_history_list_stub:invokes(function(_cwd, callback)
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

            SessionRestore.show_picker(
                mock_session --[[@as agentic.SessionManager]]
            )

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
                chat_history_list_stub:invokes(function(_cwd, callback)
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
                local replacement = session_with_load_support()
                setup_registry_stub(replacement)
                local destroy_stub = spy.stub(SessionRegistry, "destroy")
                local original_provider = Config.provider

                SessionRestore.show_picker(
                    mock_session --[[@as agentic.SessionManager]]
                )

                assert.equal("opencode-acp", Config.provider)
                assert.spy(destroy_stub).was.called(1)
                assert.equal(mock_session, destroy_stub.calls[1][1])
                assert.spy(replacement.load_acp_session).was.called(1)
                assert.spy(mock_session.load_acp_session).was.called(0)

                Config.provider = original_provider
                destroy_stub:revert()
            end
        )

        it(
            "warns but keeps current provider for sessions without provider",
            function()
                local mock_session = session_with_load_support()
                setup_list_stub() -- default test_sessions have no provider field

                SessionRestore.show_picker(
                    mock_session --[[@as agentic.SessionManager]]
                )

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

        it("detects no conflict when session_id is nil", function()
            local session = create_mock_session({
                chat_history = { messages = { { type = "user" } } },
            })
            session.session_id = nil
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(vim_fn_confirm_stub).was.called(0) -- no conflict dialogue
        end)

        it("detects no conflict when chat_history is nil", function()
            local session = create_mock_session()
            session.chat_history = nil
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(vim_fn_confirm_stub).was.called(0) -- no conflict dialogue
        end)

        it("detects no conflict when messages array is empty", function()
            local session = create_mock_session()
            setup_list_stub()

            SessionRestore.show_picker(session --[[@as agentic.SessionManager]])

            assert.spy(vim_fn_confirm_stub).was.called(0) -- no conflict dialogue
        end)
    end)

    --- @diagnostic disable: missing-fields
    describe("replay_messages", function()
        local function no_buffer()
            return nil
        end

        it("replays user and agent messages", function()
            local write_message_spy = spy.new(function() end)
            local write_prompt_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)
            local flush_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_user_prompt = write_prompt_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
                flush_thought_run = flush_spy,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    { type = "user", text = "Hello" },
                    { type = "agent", text = "Hi there" },
                },
                no_buffer
            )

            assert.equal(1, write_prompt_spy.call_count)
            assert.equal(1, write_message_spy.call_count)
        end)

        it("replays a subagent event as a notice that never finalizes", function()
            local notice_spy = spy.new(function() end)
            local writer = {
                write_notice = notice_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "subagent_event",
                        kind = "end",
                        title = "failed",
                        body = { "boom" },
                        parent_tool_use_id = "toolu_1",
                    },
                    {
                        type = "subagent_event",
                        kind = "received",
                        title = "From main agent",
                        parent_tool_use_id = "toolu_1",
                    },
                    {
                        type = "subagent_event",
                        kind = "sent",
                        title = "To main agent",
                        parent_tool_use_id = "toolu_1",
                    },
                },
                no_buffer
            )

            assert.equal(3, notice_spy.call_count)
            local ended = notice_spy.calls[1][2]
            assert.equal("failed", ended.title)
            assert.same({ "boom" }, ended.body)
            assert.is_true(ended.mid_turn)
            assert.equal(Glyphs.KIND.subagent, ended.glyph)
            assert.equal(Glyphs.MESSAGE_RECEIVED, notice_spy.calls[2][2].glyph)
            assert.equal(Glyphs.KIND.sendmessage, notice_spy.calls[3][2].glyph)
        end)

        it("a link row names the peer's buffer and carries the message id", function()
            local notice_spy = spy.new(function() end)
            local writer = {
                write_notice = notice_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "subagent_event",
                        kind = "sent",
                        title = "To finder",
                        message_id = "toolu_1",
                        peer_session_id = "c1",
                    },
                    {
                        type = "subagent_event",
                        kind = "sent",
                        title = "To gone",
                        message_id = "toolu_2",
                        peer_session_id = "c2",
                    },
                },
                function(session_id)
                    return session_id == "c1" and "agentic://1/subagent/finder"
                        or nil
                end
            )

            local linked = notice_spy.calls[1][2]
            assert.same({ "agentic://1/subagent/finder" }, linked.body)
            assert.equal("toolu_1", linked.id)
            assert.is_nil(notice_spy.calls[2][2].body)
        end)

        it("replays thought chunks", function()
            local write_message_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)
            local flush_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
                flush_thought_run = flush_spy,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    { type = "thought", text = "Thinking..." },
                },
                no_buffer
            )

            assert.equal(1, write_chunk_spy.call_count)
            -- Nothing else finalizes the replayed turn, so the run would stay
            -- buffered and surface under the next prompt.
            assert.equal(1, flush_spy.call_count)
        end)

        it("replays tool calls", function()
            local write_message_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)
            local flush_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
                flush_thought_run = flush_spy,
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
                },
                no_buffer
            )

            assert.equal(1, write_tool_spy.call_count)
        end)

        -- The record → block projection is hand-picked field by field, so a
        -- field the writer never receives is lost on replay alone, with the
        -- saved session still holding it.
        it("replays the SKILL.md path of a skill call", function()
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = spy.new(function() end),
                write_message_chunk = spy.new(function() end),
                write_tool_call_block = write_tool_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t-skill",
                        kind = "Skill",
                        argument = "coding",
                        status = "completed",
                        skill_path = "/skills/coding/SKILL.md",
                    },
                },
                no_buffer
            )

            -- Called with `:`, so the block is the second recorded argument.
            assert.equal(
                "/skills/coding/SKILL.md",
                write_tool_spy.calls[1][2].skill_path
            )
        end)

        it("replays the shell of an execute call", function()
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = spy.new(function() end),
                write_message_chunk = spy.new(function() end),
                write_tool_call_block = write_tool_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t-exec",
                        kind = "execute",
                        argument = "ls",
                        status = "completed",
                        shell = "zsh",
                    },
                },
                no_buffer
            )

            assert.equal("zsh", write_tool_spy.calls[1][2].shell)
        end)

        it("replays what decided a call's permission", function()
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = spy.new(function() end),
                write_message_chunk = spy.new(function() end),
                write_tool_call_block = write_tool_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t-grep",
                        kind = "execute",
                        argument = "grep x f > /tmp/out",
                        status = "completed",
                        decided_by = { "read-only", "grant" },
                    },
                },
                no_buffer
            )

            assert.same(
                { "read-only", "grant" },
                write_tool_spy.calls[1][2].decided_by
            )
        end)

        it(
            "replays a foldable search tool call without emitting marker lines",
            function()
                -- Persisted bodies never contained markers, so a clean
                -- re-render must signal foldability via the `-fold` fence
                -- suffix rather than re-inserting markers into buffer content.
                local MessageWriter = require("agentic.ui.message_writer")
                Config = require("agentic.config")
                local original_display = vim.deepcopy(Config.tool_call_display)
                Config.tool_call_display.execute_formatter = false

                local bufnr = vim.api.nvim_create_buf(false, true)
                local writer = MessageWriter:new(bufnr)
                local schedule_stub = spy.stub(vim, "schedule")

                local body = {}
                for i = 1, Config.tool_call_display.search_max_lines + 5 do
                    table.insert(body, "match " .. i)
                end

                SessionRestore.replay_messages(
                    writer --[[@as agentic.ui.MessageWriter]],
                    {
                        {
                            type = "tool_call",
                            tool_call_id = "replay-search",
                            kind = "search",
                            argument = "rg foo",
                            status = "completed",
                            body = body,
                        },
                    },
                    no_buffer
                )

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                for _, line in ipairs(lines) do
                    assert.are_not.equal("{{{", line)
                    assert.are_not.equal("}}}", line)
                end

                -- Foldability is encoded in the fence info string (the `-fold`
                -- suffix the writer adds), not in buffer markers or extmarks.
                local has_fold_fence = false
                for _, line in ipairs(lines) do
                    if line:match("^`+[%w]+%-fold$") then
                        has_fold_fence = true
                        break
                    end
                end
                assert.is_true(has_fold_fence)

                schedule_stub:revert()
                Config.tool_call_display = original_display
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )
    end)
end)
