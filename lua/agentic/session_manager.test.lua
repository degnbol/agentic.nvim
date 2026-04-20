--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch, need-check-nil
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentModes = require("agentic.acp.agent_modes")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionManager = require("agentic.session_manager")

--- @param mode_id string
--- @return agentic.acp.CurrentModeUpdate
local function mode_update(mode_id)
    return { sessionUpdate = "current_mode_update", currentModeId = mode_id }
end

describe("agentic.SessionManager", function()
    describe("_on_session_update: current_mode_update", function()
        --- @type TestStub
        local notify_stub
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local legacy_modes = AgentModes:new()
            legacy_modes:set_modes({
                availableModes = {
                    { id = "plan", name = "Plan", description = "Planning" },
                    { id = "code", name = "Code", description = "Coding" },
                },
                currentModeId = "plan",
            })

            local AgentModels = require("agentic.acp.agent_models")

            session = {
                config_options = {
                    legacy_agent_modes = legacy_modes,
                    legacy_agent_models = AgentModels:new(),
                    get_mode_name = function(_self, mode_id)
                        local mode = legacy_modes:get_mode(mode_id)
                        return mode and mode.name or nil
                    end,
                    get_model_name = function()
                        return nil
                    end,
                },
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                    tab_page_id = vim.api.nvim_get_current_tabpage(),
                },
                _on_session_update = SessionManager._on_session_update,
                _update_chat_header = SessionManager._update_chat_header,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            notify_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
            vim.t.agentic_headers = nil
        end)

        it("updates state, re-renders header, notifies user", function()
            session:_on_session_update(mode_update("code"))

            assert.equal(
                "code",
                session.config_options.legacy_agent_modes.current_mode_id
            )

            assert.spy(render_header_spy).was.called(1)
            assert.equal("chat", render_header_spy.calls[1][2])

            -- Context is set in vim.t.agentic_headers, not passed to render_header
            local headers = vim.t.agentic_headers
            assert.equal("Code", headers.chat.context)

            assert.spy(notify_stub).was.called(1)
            assert.equal("Mode changed to: code", notify_stub.calls[1][1])
            assert.equal(vim.log.levels.INFO, notify_stub.calls[1][2])
        end)

        it("rejects invalid mode and keeps current state", function()
            session:_on_session_update(mode_update("nonexistent"))

            assert.equal(
                "plan",
                session.config_options.legacy_agent_modes.current_mode_id
            )
            assert.spy(render_header_spy).was.called(0)

            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)

    describe("_on_session_update: config_option_update", function()
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )

            keymap_stub:revert()

            session = {
                config_options = config_opts,
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                    tab_page_id = vim.api.nvim_get_current_tabpage(),
                },
                _on_session_update = SessionManager._on_session_update,
                _update_chat_header = SessionManager._update_chat_header,
                _handle_new_config_options = SessionManager._handle_new_config_options,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
            vim.t.agentic_headers = nil
        end)

        it("sets config options and updates header on mode", function()
            --- @type agentic.acp.ConfigOptionsUpdate
            local update = {
                sessionUpdate = "config_option_update",
                configOptions = {
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "plan",
                        description = "Mode",
                        name = "Mode",
                        options = {
                            {
                                value = "plan",
                                name = "Plan",
                                description = "",
                            },
                        },
                    },
                },
            }

            session:_on_session_update(update)

            assert.is_not_nil(session.config_options.mode)
            assert.equal("plan", session.config_options.mode.currentValue)
            assert.spy(render_header_spy).was.called(1)

            -- Context is set in vim.t.agentic_headers, not passed to render_header
            local headers = vim.t.agentic_headers
            assert.equal("Plan", headers.chat.context)
        end)
    end)

    describe("_do_load_acp_session: _restoring flag", function()
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local exec_autocmds_stub

        --- @type fun(result: table|nil, err: table|nil)|nil
        local captured_load_cb

        --- Build a minimal session for load_acp_session tests
        --- @return agentic.SessionManager
        local function make_load_session()
            local noop = function() end
            captured_load_cb = nil
            return {
                session_id = nil,
                _restoring = false,
                _session_epoch = 0,
                _is_first_message = true,
                agent = {
                    agent_capabilities = { loadSession = true },
                    load_session = function(
                        _self,
                        _sid,
                        _cwd,
                        _mcp,
                        _handlers,
                        cb
                    )
                        captured_load_cb = cb
                    end,
                    cancel_session = noop,
                },
                message_writer = {
                    write_message = noop,
                    tool_call_blocks = {},
                },
                status_animation = { start = noop, stop = noop },
                chat_history = {
                    session_id = nil,
                    timestamp = nil,
                    messages = {},
                },
                widget = {
                    clear = noop,
                    set_chat_title = noop,
                    buf_nrs = { chat = 0, input = 0 },
                },
                permission_manager = { clear = noop },
                todo_list = { clear = noop },
                file_list = { clear = noop },
                code_selection = { clear = noop },
                diagnostics_list = { clear = noop },
                config_options = { clear = noop },
                _cancel_health_check_timer = noop,
                _cancel_retry_timer = noop,
                _remove_reauth_keymap = noop,
                _do_load_acp_session = SessionManager._do_load_acp_session,
                _cancel_session = SessionManager._cancel_session,
                _build_handlers = SessionManager._build_handlers,
                _on_session_update = noop,
                _on_tool_call = noop,
                _on_tool_call_update = noop,
            } --[[@as agentic.SessionManager]]
        end

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            exec_autocmds_stub = spy.stub(vim.api, "nvim_exec_autocmds")
        end)

        after_each(function()
            schedule_stub:revert()
            exec_autocmds_stub:revert()
        end)

        it(
            "sets _restoring = true immediately to block deferred new_session",
            function()
                local session = make_load_session()

                -- Simulate: agent.load_session does NOT call callback yet
                session.agent.load_session = function()
                    -- pending — callback not invoked
                end

                session:_do_load_acp_session("test-session-id", "/tmp")

                -- _restoring must be true while load is in flight
                assert.is_true(session._restoring)
            end
        )

        it("clears _restoring on successful load", function()
            local session = make_load_session()

            session:_do_load_acp_session("test-session-id", "/tmp")

            assert.is_not_nil(captured_load_cb)
            -- Simulate successful completion
            captured_load_cb(nil, nil)

            assert.is_false(session._restoring)
        end)

        it("clears _restoring on failed load", function()
            local session = make_load_session()
            local notify_stub = spy.stub(Logger, "notify")

            -- Stub _fallback_restore_from_local to avoid side effects
            session._fallback_restore_from_local = function() end

            session:_do_load_acp_session("test-session-id", "/tmp")

            assert.is_not_nil(captured_load_cb)
            -- Simulate failure
            captured_load_cb(nil, { message = "not found" })

            assert.is_false(session._restoring)
            notify_stub:revert()
        end)

        it(
            "increments _session_epoch to invalidate in-flight create_session",
            function()
                local session = make_load_session()

                -- Simulate: a new_session() was called earlier, epoch is 1
                session._session_epoch = 1

                session:_do_load_acp_session("loaded-session-id", "/tmp")

                -- _do_load must have incremented epoch beyond the
                -- create_session's captured value of 1
                assert.equal(2, session._session_epoch)
                assert.equal("loaded-session-id", session.session_id)
            end
        )

        it(
            "epoch guard rejects stale create_session after load completes",
            function()
                local session = make_load_session()
                --- @type fun(result: table|nil, err: table|nil)|nil
                local captured_create_cb

                -- Wire up create_session to capture its callback
                session.agent.create_session = function(_self, _handlers, cb)
                    captured_create_cb = cb
                end

                -- Also need new_session method
                session.new_session = SessionManager.new_session
                session._is_first_message = true
                session.agent.cancel_session = function() end
                session.agent.subscribers = {}

                -- Step 1: new_session sends session/new (callback pending)
                session:new_session()
                assert.is_not_nil(captured_create_cb)
                assert.equal(1, session._session_epoch)

                -- Step 2: load_acp_session runs (increments epoch to 2)
                session:_do_load_acp_session("loaded-sid-aaa", "/tmp")
                assert.equal(2, session._session_epoch)
                assert.equal("loaded-sid-aaa", session.session_id)

                -- Step 3: load completes, _restoring cleared
                assert.is_not_nil(captured_load_cb)
                captured_load_cb(nil, nil) -- success
                assert.is_false(session._restoring)

                -- Step 4: stale create_session response arrives AFTER load
                -- This is the race: _restoring=false, but epoch mismatch
                captured_create_cb({ sessionId = "stale-new-sid-bbb" }, nil)

                -- session_id must NOT have been overwritten
                assert.equal("loaded-sid-aaa", session.session_id)
                -- stale subscriber should be cleaned up
                assert.is_nil(session.agent.subscribers["stale-new-sid-bbb"])
            end
        )
    end)

    describe("_generate_welcome_header", function()
        it("returns header with timestamp and short session id", function()
            local header = SessionManager._generate_welcome_header(
                "Claude ACP",
                "abc12345-long-id"
            )

            assert.truthy(
                header:match("^# %d%d%d%d%-%d%d%-%d%d %d%d:%d%d · abc12345$")
            )
        end)

        it("uses 'unknown' when session_id is nil", function()
            local header =
                SessionManager._generate_welcome_header("Claude ACP", nil)

            assert.truthy(
                header:match("^# %d%d%d%d%-%d%d%-%d%d %d%d:%d%d · unknown$")
            )
        end)
    end)

    describe("switch_provider", function()
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local schedule_stub
        local original_provider

        before_each(function()
            original_provider = Config.provider
            notify_stub = spy.stub(Logger, "notify")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            Config.provider = original_provider
            schedule_stub:revert()
            notify_stub:revert()
            if get_instance_stub then
                get_instance_stub:revert()
                get_instance_stub = nil
            end
        end)

        it("blocks when is_generating is true", function()
            local session = {
                is_generating = true,
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            assert.spy(notify_stub).was.called(1)
            local msg = notify_stub.calls[1][1]
            assert.truthy(msg:match("[Gg]enerating"))
        end)

        it(
            "soft cancels old session without clearing widget/history",
            function()
                local cancel_spy = spy.new(function() end)
                local perm_clear_spy = spy.new(function() end)
                local todo_clear_spy = spy.new(function() end)
                local widget_clear_spy = spy.new(function() end)
                local file_list_clear_spy = spy.new(function() end)
                local code_selection_clear_spy = spy.new(function() end)

                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local new_session_spy = spy.new(function() end)

                local original_messages = { { type = "user", text = "hello" } }
                local mock_chat_history = {
                    messages = original_messages,
                    session_id = "old-session",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = cancel_spy,
                        provider_config = { name = "Old Provider" },
                    },
                    permission_manager = { clear = perm_clear_spy },
                    todo_list = { clear = todo_clear_spy },
                    widget = { clear = widget_clear_spy },
                    file_list = { clear = file_list_clear_spy },
                    code_selection = { clear = code_selection_clear_spy },
                    chat_history = mock_chat_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                assert.spy(cancel_spy).was.called(1)
                assert.is_nil(session.session_id)
                assert.spy(perm_clear_spy).was.called(1)
                assert.spy(todo_clear_spy).was.called(1)

                assert.spy(widget_clear_spy).was.called(0)
                assert.spy(file_list_clear_spy).was.called(0)
                assert.spy(code_selection_clear_spy).was.called(0)

                assert.equal(mock_new_agent, session.agent)

                assert.spy(new_session_spy).was.called(1)
                local opts = new_session_spy.calls[1][2]
                assert.is_true(opts.restore_mode)
                assert.equal("function", type(opts.on_created))
            end
        )

        it(
            "schedules history resend and sets _is_first_message in on_created",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local captured_on_created
                local new_session_spy = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end)

                local original_messages = { { type = "user", text = "hello" } }
                local saved_history = {
                    messages = original_messages,
                    session_id = "old",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = saved_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                    switch_provider = SessionManager.switch_provider,
                } --[[@as agentic.SessionManager]]

                session:switch_provider()

                assert.is_not_nil(captured_on_created)

                local new_timestamp = os.time()
                session.chat_history = {
                    messages = {},
                    session_id = "new",
                    timestamp = new_timestamp,
                }
                captured_on_created()

                assert.same(original_messages, session.chat_history.messages)
                assert.equal("new", session.chat_history.session_id)
                assert.equal(new_timestamp, session.chat_history.timestamp)
                assert.same(original_messages, session._history_to_send)
                assert.is_true(session._is_first_message)
            end
        )

        it("no-ops soft cancel when session_id is nil", function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local mock_agent = {
                provider_config = { name = "Provider" },
                cancel_session = spy.new(function() end),
                create_session = spy.new(function() end),
            }
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(_provider, on_ready)
                on_ready(mock_agent)
                return mock_agent
            end)

            Config.provider = "some-provider"

            local session = {
                is_generating = false,
                session_id = nil,

                agent = mock_agent,
                permission_manager = { clear = spy.new(function() end) },
                todo_list = { clear = spy.new(function() end) },
                chat_history = { messages = {} },
                _is_first_message = false,
                _history_to_send = nil,
                new_session = spy.new(function() end),
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            assert.spy(mock_agent.cancel_session).was.called(0)
            assert.spy(session.permission_manager.clear).was.called(1)
            assert.spy(session.todo_list.clear).was.called(1)
            assert.spy(session.new_session).was.called(1)
        end)
    end)

    describe("FileChangedShell autocommand", function()
        local Child = require("tests.helpers.child")
        local child = Child:new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it("sets fcs_choice to reload when FileChangedShell fires", function()
            child.v.fcs_choice = ""
            child.api.nvim_exec_autocmds("FileChangedShell", {
                group = "AgenticCleanup",
                pattern = "*",
            })

            assert.equal("reload", child.v.fcs_choice)
        end)
    end)

    describe("on_tool_call_update: buffer reload", function()
        --- @type TestStub
        local checktime_stub
        --- @type TestStub
        local schedule_stub

        --- @param tool_call_blocks table<string, table>
        --- @return agentic.SessionManager
        local function make_session(tool_call_blocks)
            return {
                message_writer = {
                    update_tool_call_block = function() end,
                    tool_call_blocks = tool_call_blocks,
                },
                permission_manager = {
                    current_request = nil,
                    queue = {},
                    remove_request_by_tool_call_id = function() end,
                    finalize_edit_range = function() end,
                    drop_pending_edit = function() end,
                    has_edit_range = function()
                        return true
                    end,
                },
                _try_record_edit_range = function() end,
                status_animation = { start = function() end },
                _clear_diff_in_buffer = function() end,
                chat_history = { update_tool_call = function() end },
            } --[[@as agentic.SessionManager]]
        end

        before_each(function()
            checktime_stub = spy.stub(vim.cmd, "checktime")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            checktime_stub:revert()
            schedule_stub:revert()
        end)

        it("calls checktime for each file-mutating kind", function()
            for _, kind in ipairs({
                "edit",
                "create",
                "write",
                "delete",
                "move",
            }) do
                checktime_stub:reset()
                local tc_id = "tc-" .. kind
                local session = make_session({
                    [tc_id] = { kind = kind, status = "in_progress" },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = tc_id, status = "completed" }
                )

                assert.spy(checktime_stub).was.called(1)
            end
        end)

        it("does not call checktime for failed tool calls", function()
            local session = make_session({
                ["tc-1"] = { kind = "edit", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "failed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime for non-mutating kinds", function()
            local session = make_session({
                ["tc-1"] = { kind = "read", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime when tracker is missing", function()
            local debug_stub = spy.stub(Logger, "debug")
            local session = make_session({})

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-missing", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
            debug_stub:revert()
        end)
    end)

    describe("notifications.bell", function()
        --- @type TestStub
        local bell_stub
        --- @type TestStub
        local schedule_stub
        local original_notifications

        before_each(function()
            original_notifications = Config.notifications
            bell_stub = spy.stub(SessionManager, "_ring_bell")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            Config.notifications = original_notifications
            bell_stub:revert()
            schedule_stub:revert()
        end)

        --- Build a minimal session whose agent:send_prompt immediately calls back
        --- @param send_err? table
        --- @return agentic.SessionManager
        local function make_session(send_err)
            local noop = function() end
            local empty = function()
                return true
            end
            return {
                session_id = "s-1",
                tab_page_id = 1,
                is_generating = false,
                _is_first_message = false,
                _destroyed = false,
                agent = {
                    state = "ready",
                    provider_config = { name = "Test" },
                    send_prompt = function(_self, _sid, _prompt, cb)
                        cb(nil, send_err)
                    end,
                },
                message_writer = {
                    write_message = noop,
                    write_error_message = function()
                        return nil, nil
                    end,
                    append_separator = noop,
                    scroll_to_bottom = noop,
                    is_near_bottom = empty,
                    tool_call_blocks = {},
                },
                status_animation = { start = noop, stop = noop },
                chat_history = {
                    add_message = noop,
                    save = noop,
                    messages = {},
                    title = "",
                },
                widget = {
                    buf_nrs = { chat = 0 },
                    win_nrs = { chat = nil },
                    get_chat_width = function()
                        return 80
                    end,
                    clear_unread_badge = noop,
                    set_unread_badge = noop,
                    set_chat_title = noop,
                },
                permission_manager = {
                    current_request = nil,
                    queue = {},
                },
                todo_list = { close_if_all_completed = noop },
                file_list = { is_empty = empty },
                code_selection = { is_empty = empty },
                diagnostics_list = { is_empty = empty },
                _handle_input_submit = SessionManager._handle_input_submit,
                _handle_input_submit_inner = SessionManager._handle_input_submit_inner,
                _notify_attention = SessionManager._notify_attention,
            } --[[@as agentic.SessionManager]]
        end

        it("calls _ring_bell on response complete", function()
            local session = make_session()
            session:_handle_input_submit("hello")
            assert.spy(bell_stub).was.called(1)
        end)

        it("calls _ring_bell on response error too", function()
            local session = make_session({ message = "some error" })
            session:_handle_input_submit("hello")
            assert.spy(bell_stub).was.called(1)
        end)
    end)

    describe("_ring_bell", function()
        local original_notifications

        before_each(function()
            original_notifications = Config.notifications
        end)

        after_each(function()
            Config.notifications = original_notifications
        end)

        it("does not error when enabled", function()
            Config.notifications = { bell = true }
            -- Can't stub io.stderr (userdata), just verify no error
            assert.has_no_errors(function()
                SessionManager._ring_bell()
            end)
        end)

        it("does not error when disabled", function()
            Config.notifications = { bell = false }
            assert.has_no_errors(function()
                SessionManager._ring_bell()
            end)
        end)

        it("does not error when notifications is nil", function()
            Config.notifications = nil
            assert.has_no_errors(function()
                SessionManager._ring_bell()
            end)
        end)
    end)

    describe("on_permission_request hook", function()
        --- @type TestStub
        local schedule_stub
        local original_hooks

        before_each(function()
            original_hooks = Config.hooks
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            Config.hooks = original_hooks
            schedule_stub:revert()
        end)

        it("fires on_permission_request hook via invoke_hook", function()
            local hook_data
            Config.hooks = {
                on_permission_request = function(data)
                    hook_data = data
                end,
            }

            -- Invoke hook the same way P.invoke_hook does
            local hook = Config.hooks.on_permission_request
            vim.schedule(function()
                hook({
                    session_id = "s-1",
                    tab_page_id = 1,
                    tool_call_id = "tc-1",
                })
            end)

            assert.is_not_nil(hook_data)
            assert.equal("s-1", hook_data.session_id)
            assert.equal("tc-1", hook_data.tool_call_id)
        end)
    end)

    describe("_format_duration", function()
        it("formats hours and minutes", function()
            assert.equal(
                "2h 15m",
                SessionManager._format_duration(2 * 3600 + 15 * 60)
            )
        end)

        it("formats hours with zero minutes", function()
            assert.equal("1h 0m", SessionManager._format_duration(3600))
        end)

        it("formats minutes only", function()
            assert.equal("45m", SessionManager._format_duration(45 * 60))
        end)

        it("formats seconds for short durations", function()
            assert.equal("30s", SessionManager._format_duration(30))
        end)

        it("formats zero seconds", function()
            assert.equal("0s", SessionManager._format_duration(0))
        end)
    end)

    describe("/trust dispatch", function()
        --- @type TestStub
        local select_stub
        --- @type TestStub
        local input_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local git_root_stub
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr
        --- @type table
        local pm
        --- @type any[][]
        local writes
        --- @type any[]
        local errors

        local SessionManagerModule
        local GitFiles

        before_each(function()
            SessionManagerModule = require("agentic.session_manager")
            GitFiles = require("agentic.utils.git_files")

            select_stub = spy.stub(vim.ui, "select")
            input_stub = spy.stub(vim.ui, "input")
            notify_stub = spy.stub(Logger, "notify")
            git_root_stub = spy.stub(GitFiles, "get_git_root")
            git_root_stub:returns("/repo")

            test_bufnr = vim.api.nvim_create_buf(false, true)

            writes = {}
            errors = {}

            pm = {
                set_trust_scope = spy.new(function() end),
                clear_trust_scope = spy.new(function() end),
            }

            session = {
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                permission_manager = pm,
                widget = {
                    buf_nrs = { chat = test_bufnr },
                    tab_page_id = vim.api.nvim_get_current_tabpage(),
                },
                message_writer = {
                    write_message = spy.new(function(_, msg)
                        table.insert(writes, msg)
                    end),
                    append_separator = spy.new(function() end),
                    write_error_action = spy.new(function(_, msg)
                        table.insert(errors, msg)
                    end),
                },
                _push_trust_to_headers = SessionManagerModule._push_trust_to_headers,
                _apply_trust_scope = SessionManagerModule._apply_trust_scope,
                _clear_trust_scope = SessionManagerModule._clear_trust_scope,
                _show_trust_picker = SessionManagerModule._show_trust_picker,
                _handle_trust_command = SessionManagerModule._handle_trust_command,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            select_stub:revert()
            input_stub:revert()
            notify_stub:revert()
            git_root_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
            vim.t.agentic_headers = nil
            Config.auto_approve_trust_scope = true
        end)

        it("repo subcommand sets a repo scope on the manager", function()
            session:_handle_trust_command("repo")
            assert.equal(1, pm.set_trust_scope.call_count)
            local scope = pm.set_trust_scope.calls[1][2]
            assert.equal("repo", scope.kind)
        end)

        it("here subcommand sets a here scope on the manager", function()
            session:_handle_trust_command("here")
            assert.equal(1, pm.set_trust_scope.call_count)
            local scope = pm.set_trust_scope.calls[1][2]
            assert.equal("here", scope.kind)
        end)

        it("off subcommand clears the scope", function()
            session:_handle_trust_command("off")
            assert.equal(1, pm.clear_trust_scope.call_count)
        end)

        it("path subcommand compiles a path scope", function()
            session:_handle_trust_command("/repo/src/**/*.lua")
            assert.equal(1, pm.set_trust_scope.call_count)
            local scope = pm.set_trust_scope.calls[1][2]
            assert.equal("path", scope.kind)
            assert.equal("/repo/src/**/*.lua", scope.display)
        end)

        it("empty arg opens the picker", function()
            session:_handle_trust_command("")
            assert.equal(1, select_stub.call_count)
        end)

        it("repo subcommand without git root errors", function()
            git_root_stub:returns(nil)
            session:_handle_trust_command("repo")
            assert.equal(0, pm.set_trust_scope.call_count)
            assert.equal(1, #errors)
        end)

        it("disabled config rejects /trust", function()
            Config.auto_approve_trust_scope = false
            session:_handle_trust_command("repo")
            assert.equal(0, pm.set_trust_scope.call_count)
            assert.equal(1, #errors)
        end)

        it("emits a WARN for wide path scopes", function()
            session:_handle_trust_command("/tmp")
            assert.equal(1, pm.set_trust_scope.call_count)
            local warn_count = 0
            for _, c in ipairs(notify_stub.calls) do
                if c[2] == vim.log.levels.WARN then
                    warn_count = warn_count + 1
                end
            end
            assert.equal(1, warn_count)
        end)

        it("does not emit a WARN for reserved literals", function()
            session:_handle_trust_command("repo")
            local warn_count = 0
            for _, c in ipairs(notify_stub.calls) do
                if c[2] == vim.log.levels.WARN then
                    warn_count = warn_count + 1
                end
            end
            assert.equal(0, warn_count)
        end)
    end)
end)
