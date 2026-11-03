--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch, need-check-nil
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local ACPClient = require("agentic.acp.acp_client")
local AgentConfigOptions = require("agentic.acp.agent_config_options")
local AgentModes = require("agentic.acp.agent_modes")
local AgentView = require("agentic.ui.agent_view")
local ChatHistory = require("agentic.ui.chat_history")
local FileSystem = require("agentic.utils.file_system")
local Config = require("agentic.config")
local Deferred = require("tests.helpers.deferred")
local Budget = require("agentic.budget")
local Glyphs = require("agentic.glyphs")
local Logger = require("agentic.utils.logger")
local MiniTest = require("mini.test")
local SessionManager = require("agentic.session_manager")
local Subagents = require("agentic.subagents")

--- @param mode_id string
--- @return agentic.acp.CurrentModeUpdate
local function mode_update(mode_id)
    return { sessionUpdate = "current_mode_update", currentModeId = mode_id }
end

local last_id = 0

--- A fresh `SessionManager.id`.
--- @return integer
local function fresh_id()
    last_id = last_id + 1
    return last_id
end

--- The main view of a fake session: an `AgentView` of its writer and
--- indicator.
--- @param session agentic.SessionManager
--- @return agentic.ui.AgentView
local function fake_main_view(session)
    return setmetatable({
        writer = session.message_writer,
        status_indicator = session.status_indicator,
    }, { __index = AgentView }) --[[@as agentic.ui.AgentView]]
end

--- Give a fake session a real `Subagents` with no subagents, reaching the
--- session through its host, and a main view of its writer and indicator
--- unless it has one.
--- @param session agentic.SessionManager
--- @return agentic.SessionManager session
local function with_subagents(session)
    session.main_view = session.main_view or fake_main_view(session)
    session._subagents = Subagents:new(
        session.widget,
        session.main_view,
        SessionManager._subagents_host(session)
    )
    return session
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
                id = fresh_id(),
                config_options = {
                    legacy_agent_modes = legacy_modes,
                    legacy_agent_models = AgentModels:new(),
                    current_mode_id = AgentConfigOptions.current_mode_id,
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
                    buf_nrs = { agent = test_bufnr },
                },
                _on_session_update = SessionManager._on_session_update,
                render_info = function() end,
                _update_chat_header = SessionManager._update_chat_header,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            notify_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("updates state without notifying or touching the header", function()
            session:_on_session_update(mode_update("code"))

            assert.equal(
                "code",
                session.config_options.legacy_agent_modes.current_mode_id
            )

            assert.spy(render_header_spy).was.called(0)
            assert.spy(notify_stub).was.called(0)
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

            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new(
                function() end,
                function() end
            )

            keymap_stub:revert()

            session = with_subagents({
                id = fresh_id(),
                config_options = config_opts,
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { agent = test_bufnr },
                },
                _on_session_update = SessionManager._on_session_update,
                render_info = function() end,
                _update_chat_header = SessionManager._update_chat_header,
                _handle_new_config_options = SessionManager._handle_new_config_options,
            } --[[@as agentic.SessionManager]])
        end)

        after_each(function()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("sets config options without touching the header", function()
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
            assert.spy(render_header_spy).was.called(0)
        end)
    end)

    describe("header state", function()
        it("_set_generating sets the field and the chat's running", function()
            local set_running = spy.new(function() end)
            local session = {
                widget = { set_running = set_running },
                _set_generating = SessionManager._set_generating,
            } --[[@as agentic.SessionManager]]

            session:_set_generating(true)

            assert.is_true(session.is_generating)
            assert.spy(set_running).was.called_with(session.widget, true)
        end)

        it("_update_chat_header shows only tokens", function()
            local render_header = spy.new(function() end)
            local session = {
                config_options = {
                    current_mode_id = function()
                        return "plan"
                    end,
                },
                file_activity = {
                    count = function()
                        return 3
                    end,
                },
                _usage = { used = 123400, size = 200000 },
                widget = { render_header = render_header },
                _update_chat_header = SessionManager._update_chat_header,
            } --[[@as agentic.SessionManager]]

            session:_update_chat_header()

            assert
                .spy(render_header).was
                .called_with(session.widget, "agent", "123k")
        end)
    end)

    describe("_on_session_update: session_info_update", function()
        --- @param title string
        --- @return agentic.acp.SessionInfoUpdateMessage
        local function info_update(title)
            return { sessionUpdate = "session_info_update", title = title }
        end

        --- @param current_title string Title already on the session
        --- @param user_renamed boolean Whether the user issued /rename
        local function make_session(current_title, user_renamed)
            local set_title_spy = spy.new(function() end)
            local save_spy = spy.new(function() end)
            local chat_history = ChatHistory:new()
            chat_history.session_id = "s-1"
            chat_history.title = current_title
            chat_history:add_message({
                type = "user",
                text = "do the thing",
                timestamp = 0,
                provider_name = "p",
            })
            chat_history.save = save_spy
            local session = {
                _title_user_set = user_renamed,
                _prompt_pending = 0,
                chat_history = chat_history,
                widget = {
                    buf_nrs = {},
                    set_chat_title = set_title_spy,
                },
                _sync_history_context = function() end,
                _persist_history = SessionManager._persist_history,
                _history_changed = SessionManager._history_changed,
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
                _on_session_update = SessionManager._on_session_update,
                render_info = function() end,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            return session, set_title_spy, save_spy
        end

        it(
            "adopts the auto-summary, overriding a first-prompt title",
            function()
                local session, set_title_spy, save_spy =
                    make_session("do the thing", false)

                session:_on_session_update(info_update("Fix the parser bug"))

                assert.equal("Fix the parser bug", session.chat_history.title)
                assert.spy(set_title_spy).was.called(1)
                assert.equal("Fix the parser bug", set_title_spy.calls[1][2])
                assert.spy(save_spy).was.called(1)
            end
        )

        it("keeps a /rename'd title (never clobbers a user title)", function()
            local session, set_title_spy, save_spy =
                make_session("My renamed session", true)

            session:_on_session_update(info_update("Auto generated summary"))

            assert.equal("My renamed session", session.chat_history.title)
            assert.spy(set_title_spy).was.called(0)
            assert.spy(save_spy).was.called(0)
        end)

        it("ignores an empty pushed title", function()
            local session, set_title_spy, save_spy = make_session("", false)

            session:_on_session_update(info_update(""))

            assert.equal("", session.chat_history.title)
            assert.spy(set_title_spy).was.called(0)
            assert.spy(save_spy).was.called(0)
        end)

        it("clears _title_user_set on session reset (/new, /clear)", function()
            local Recovery = require("agentic.session_recovery")
            local SlashCommands = require("agentic.acp.slash_commands")
            local stubs = {
                spy.stub(Recovery, "cancel_retry_timer"),
                spy.stub(SlashCommands, "setCommands"),
            }

            local session = {
                session_id = nil, -- skip the cancel/clear-content block
                _title_user_set = true, -- as if the user had /rename'd
                permission_manager = {
                    clear = function() end,
                },
                widget = {
                    buf_nrs = { input = 0 },
                    set_chat_title = function() end,
                    set_running = function() end,
                    set_idle = function() end,
                },
                _cancel_session = SessionManager._cancel_session,
                _reset_conversation = SessionManager._reset_conversation,
                _set_available_commands = SessionManager._set_available_commands,
                render_info = function() end,
                _set_generating = SessionManager._set_generating,
                _update_chat_header = function() end,
                chat_history = ChatHistory:new(),
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)

            session:_cancel_session()

            assert.is_false(session._title_user_set)

            for _, s in ipairs(stubs) do
                s:revert()
            end
        end)

        it(
            "resets is_generating and stops indicators on reset mid-turn",
            function()
                local Recovery = require("agentic.session_recovery")
                local SlashCommands = require("agentic.acp.slash_commands")
                local stubs = {
                    spy.stub(Recovery, "cancel_retry_timer"),
                    spy.stub(SlashCommands, "setCommands"),
                }

                local noop = function() end
                local status_stop = spy.new(noop)
                local session = {
                    session_id = "live-session", -- exercise the teardown block
                    is_generating = true, -- as if a turn were streaming
                    agent = { cancel_session = noop },
                    permission_manager = {
                        clear = noop,
                    },
                    todo_list = { clear = noop },
                    file_list = { clear = noop },
                    code_selection = { clear = noop },
                    diagnostics_list = { clear = noop },
                    config_options = { clear = noop },
                    file_activity = { clear = noop },
                    status_indicator = { stop = status_stop },
                    widget = {
                        buf_nrs = { input = 0 },
                        clear = noop,
                        set_chat_title = noop,
                        set_running = noop,
                        set_idle = noop,
                    },
                    message_writer = { reset = noop },
                    clear_chat = SessionManager.clear_chat,
                    _output_tails = {},
                    _stop_output_tails = SessionManager._stop_output_tails,
                    _cancel_session = SessionManager._cancel_session,
                    _reset_conversation = SessionManager._reset_conversation,
                    _set_available_commands = SessionManager._set_available_commands,
                    render_info = function() end,
                    _set_generating = SessionManager._set_generating,
                    _update_chat_header = function() end,
                    chat_history = ChatHistory:new(),
                    _sync_modified = SessionManager._sync_modified,
                    _set_prompt_pending = SessionManager._set_prompt_pending,
                } --[[@as agentic.SessionManager]]
                with_subagents(session)

                session:_cancel_session()

                assert.is_false(session.is_generating)
                assert.spy(status_stop).was.called(1)

                for _, s in ipairs(stubs) do
                    s:revert()
                end
            end
        )
    end)

    describe("_reset_conversation", function()
        local Recovery = require("agentic.session_recovery")
        local SlashCommands = require("agentic.acp.slash_commands")
        local noop = function() end

        --- @type TestStub[]
        local stubs

        before_each(function()
            stubs = {
                spy.stub(Recovery, "cancel_retry_timer"),
                spy.stub(SlashCommands, "setCommands"),
            }
        end)

        after_each(function()
            for _, s in ipairs(stubs) do
                s:revert()
            end
        end)

        --- @param update_chat_header fun(self: agentic.SessionManager)|nil
        --- @return agentic.SessionManager
        local function make_session(update_chat_header)
            return with_subagents({
                session_id = "old-sid",
                permission_manager = { clear = noop },
                todo_list = { clear = noop },
                file_list = { clear = noop },
                code_selection = { clear = noop },
                diagnostics_list = { clear = noop },
                config_options = { clear = noop },
                file_activity = { clear = noop },
                status_indicator = { stop = spy.new(noop) },
                widget = {
                    buf_nrs = { input = 0 },
                    clear = noop,
                    set_chat_title = noop,
                    set_running = noop,
                    set_idle = noop,
                },
                message_writer = { reset = noop },
                clear_chat = SessionManager.clear_chat,
                _output_tails = {},
                _stop_output_tails = SessionManager._stop_output_tails,
                _reset_conversation = SessionManager._reset_conversation,
                _set_available_commands = SessionManager._set_available_commands,
                render_info = function() end,
                _set_generating = SessionManager._set_generating,
                _update_chat_header = update_chat_header or noop,
                chat_history = ChatHistory:new(),
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
            } --[[@as agentic.SessionManager]])
        end

        it("lets the next conversation take the provider title", function()
            local session = make_session()
            session._title_user_set = true

            session:_reset_conversation()

            assert.is_false(session._title_user_set)
        end)

        it("drops the token count before the header update", function()
            --- @type table|nil
            local seen
            local session = make_session(function(this)
                seen = {
                    usage = this._usage,
                    session_id = this.session_id,
                    title_user_set = this._title_user_set,
                    history_to_send = this._history_to_send,
                }
            end)
            session._usage = { used = 1000, size = 200000 }
            session._title_user_set = true
            session._history_to_send = {}

            session:_reset_conversation()

            assert.same({ title_user_set = false }, seen)
        end)

        it("ends a running turn", function()
            local session = make_session()
            session.is_generating = true

            session:_reset_conversation()

            assert.is_false(session.is_generating)
            assert.spy(session.status_indicator.stop).was.called(1)
        end)

        it("keeps the load gate", function()
            local session = make_session()
            session._loading = true

            session:_reset_conversation()

            assert.is_true(session._loading)
        end)

        it("renders the info panel without the usage", function()
            local session = make_session()
            session._usage = { used = 1000, size = 200000 }
            local usage_at_render = "unset"
            session.render_info = function(this)
                usage_at_render = this._usage
            end

            session:_reset_conversation()

            assert.is_nil(usage_at_render)
        end)
    end)

    describe("_on_session_update: usage_update", function()
        --- @param fields table|nil Extra usage_update fields (cost, _meta)
        --- @return agentic.acp.UsageUpdate
        local function usage_update(fields)
            return vim.tbl_extend("force", {
                sessionUpdate = "usage_update",
                used = 1000,
                size = 200000,
            }, fields or {}) --[[@as agentic.acp.UsageUpdate]]
        end

        --- @type TestStub
        local record_stub

        before_each(function()
            record_stub = spy.stub(Budget, "record")
        end)

        after_each(function()
            record_stub:revert()
        end)

        --- @param windows agentic.acp.BudgetWindow[]|nil What the agent reports
        --- @return agentic.SessionManager
        local function make_session(windows)
            return {
                agent = {
                    budget_windows = function()
                        return windows
                    end,
                },
                _update_chat_header = function() end,
                _on_session_update = SessionManager._on_session_update,
                render_info = function() end,
            } --[[@as agentic.SessionManager]]
        end

        it("records the windows the agent reports", function()
            local windows = {
                {
                    label = "5h",
                    utilization = 0.5,
                    resets_at = os.time() + 9000,
                    window_s = 5 * 3600,
                    state = "ok",
                },
            }

            make_session(windows):_on_session_update(usage_update())

            assert.same(windows, record_stub.calls[1][1])
        end)

        it("records nothing when the agent reports no windows", function()
            make_session(nil):_on_session_update(usage_update())

            assert.spy(record_stub).was.called(0)
        end)

        it("preserves prior cost when the update omits it", function()
            local session = make_session()
            session._usage = {
                used = 1,
                size = 2,
                cost = { amount = 1.5, currency = "USD" },
            }

            session:_on_session_update(usage_update())

            assert.equal(1.5, session._usage.cost.amount)
        end)

        it("renders the info panel with the new usage", function()
            local session = make_session()
            local used_at_render
            session.render_info = function(this)
                used_at_render = this._usage.used
            end

            session:_on_session_update(usage_update())

            assert.equal(1000, used_at_render)
        end)

        -- /new is exempt from the deferral gate precisely so it stays
        -- reachable to unwedge one. A load that never completes would
        -- otherwise defer every submit into the fresh session.
        it("opens every gate on session reset (/new, /clear)", function()
            local Recovery = require("agentic.session_recovery")
            local SlashCommands = require("agentic.acp.slash_commands")
            local stubs = {
                spy.stub(Recovery, "cancel_retry_timer"),
                spy.stub(SlashCommands, "setCommands"),
            }

            local session = {
                session_id = nil, -- skip the cancel/clear-content block
                agent = { state = "ready" },
                _loading = true,
                _prompt_pending = 0,
                _usage_reset_epoch = os.time() + 3600,
                _pending_bufferless_prompt = "stranded",
                permission_manager = {
                    clear = function() end,
                },
                widget = {
                    buf_nrs = { input = 0 },
                    set_chat_title = function() end,
                    set_running = function() end,
                    set_idle = function() end,
                },
                _cancel_session = SessionManager._cancel_session,
                _reset_conversation = SessionManager._reset_conversation,
                _set_available_commands = SessionManager._set_available_commands,
                render_info = function() end,
                _set_generating = SessionManager._set_generating,
                _update_chat_header = function() end,
                chat_history = ChatHistory:new(),
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
                _submit_defer_reason = SessionManager._submit_defer_reason,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)

            session:_cancel_session()

            assert.is_false(session._loading)
            assert.is_nil(session._usage_reset_epoch)
            assert.is_nil(session._pending_bufferless_prompt)
            -- Only the fresh session's own readiness is left to wait on.
            assert.equal("not_ready", session:_submit_defer_reason("hello"))

            for _, s in ipairs(stubs) do
                s:revert()
            end
        end)
    end)

    describe("_do_load_acp_session: _loading_saved flag", function()
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
            return with_subagents({
                session_id = nil,
                _loading_saved = false,
                _session_epoch = 0,
                _is_first_message = true,
                agent = {
                    agent_capabilities = { loadSession = true },
                    subscribers = {},
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
                    unsubscribe = function(this, session_id)
                        this.subscribers[session_id] = nil
                    end,
                    provider_config = { name = "Test" },
                },
                message_writer = {
                    write_message = noop,
                    write_notice = noop,
                    reset = noop,
                    tool_call_blocks = {},
                },
                status_indicator = { start = noop, stop = noop },
                chat_history = {
                    session_id = nil,
                    timestamp = nil,
                    messages = {},
                    subagents = {},
                    has_prompt = ChatHistory.has_prompt,
                },
                widget = {
                    clear = noop,
                    set_chat_title = noop,
                    set_running = noop,
                    set_idle = noop,
                    buf_nrs = { agent = 0, input = 0 },
                },
                permission_manager = { clear = noop },
                todo_list = { clear = noop },
                file_list = { clear = noop },
                code_selection = { clear = noop },
                diagnostics_list = { clear = noop },
                config_options = {
                    clear = noop,
                    current_model_id = noop,
                    set_pending_initial_model = noop,
                },
                file_activity = { clear = noop, load = noop },
                clear_chat = SessionManager.clear_chat,
                _output_tails = {},
                _stop_output_tails = SessionManager._stop_output_tails,
                _cancel_retry_timer = noop,
                _do_load_acp_session = SessionManager._do_load_acp_session,
                _apply_session_options = SessionManager._apply_session_options,
                _reapply_model = SessionManager._reapply_model,
                announce_model_loaded = SessionManager.announce_model_loaded,
                _advance_session_epoch = SessionManager._advance_session_epoch,
                _prompt_pending = 0,
                _dispatch_deferred_prompts = noop,
                _cancel_session = SessionManager._cancel_session,
                _reset_conversation = SessionManager._reset_conversation,
                _set_available_commands = SessionManager._set_available_commands,
                render_info = function() end,
                _set_generating = SessionManager._set_generating,
                _update_chat_header = function() end,
                _install_history = SessionManager._install_history,
                _render_history = noop,
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
                _build_handlers = SessionManager._build_handlers,
                _grant_command = { apply_defaults = noop },
                _on_session_update = noop,
                _on_tool_call = noop,
                _on_tool_call_update = noop,
            } --[[@as agentic.SessionManager]])
        end

        local original_storage_path

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            exec_autocmds_stub = spy.stub(vim.api, "nvim_exec_autocmds")
            -- A load looks up the saved file in every project folder.
            original_storage_path = Config.sessions.storage_path
            Config.sessions.storage_path = vim.fn.tempname()
        end)

        after_each(function()
            schedule_stub:revert()
            exec_autocmds_stub:revert()
            Config.sessions.storage_path = original_storage_path
        end)

        it(
            "sets _loading_saved = true immediately to block deferred new_session",
            function()
                local session = make_load_session()

                -- Simulate: agent.load_session does NOT call callback yet
                session.agent.load_session = function()
                    -- pending — callback not invoked
                end

                session:_do_load_acp_session("test-session-id", "/tmp")

                -- _loading_saved must be true while load is in flight
                assert.is_true(session._loading_saved)
            end
        )

        it("clears the outgoing session's permission state", function()
            local session = make_load_session()
            local clear = spy.new(function() end)
            session.permission_manager.clear = clear

            session:_do_load_acp_session("test-session-id", "/tmp")

            assert.equal(1, clear.call_count)
        end)

        describe("on a live session", function()
            --- @return agentic.SessionManager
            local function make_live_session()
                local session = make_load_session()
                session.session_id = "old-sid"
                return session
            end

            it("holds the load gate after the reset", function()
                local session = make_live_session()

                session:_do_load_acp_session("test-session-id", "/tmp")

                assert.is_true(session._loading)
            end)

            it("takes the title of the saved file", function()
                local session = make_live_session()
                local find_stub = spy.stub(ChatHistory, "find_files")
                find_stub:returns({ "/saved/test-session-id.json" })
                local read_stub = spy.stub(FileSystem, "read_json")
                read_stub:returns({ title = "Saved title", messages = {} })

                session:_do_load_acp_session("test-session-id", "/tmp")
                find_stub:revert()
                read_stub:revert()

                assert.is_true(session._title_user_set)
                assert.equal("Saved title", session.chat_history.title)
            end)
        end)

        it("warns when the saved file cannot be read", function()
            local session = make_load_session()
            local find_stub = spy.stub(ChatHistory, "find_files")
            find_stub:returns({ "/saved/test-session-id.json" })
            local read_stub = spy.stub(FileSystem, "read_json")
            read_stub:invokes(function(path)
                return nil, "JSON decode error in " .. path
            end)
            local notify_stub = spy.stub(Logger, "notify")

            session:_do_load_acp_session("test-session-id", "/tmp")
            find_stub:revert()
            read_stub:revert()
            notify_stub:revert()

            assert.equal(1, notify_stub.call_count)
            local message = notify_stub.calls[1][1]
            assert.truthy(message:find("/saved/test-session-id.json", 1, true))
            assert.truthy(message:find("JSON decode error", 1, true))
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)

        for _, case in ipairs({
            { given = nil, expected = "/saved/project" },
            { given = "/given/project", expected = "/given/project" },
        }) do
            it(
                "takes the cwd "
                    .. (case.given and "given" or "of the saved file"),
                function()
                    local session = make_load_session()
                    local find_stub = spy.stub(ChatHistory, "find_files")
                    find_stub:returns({ "/saved/test-session-id.json" })
                    local read_stub = spy.stub(FileSystem, "read_json")
                    read_stub:returns({
                        title = "",
                        cwd = "/saved/project",
                        messages = {},
                    })

                    session:_do_load_acp_session("test-session-id", case.given)
                    find_stub:revert()
                    read_stub:revert()

                    assert.equal(case.expected, session._cwd)
                end
            )
        end

        it("clears _loading_saved on successful load", function()
            local session = make_load_session()

            session:_do_load_acp_session("test-session-id", "/tmp")

            assert.is_not_nil(captured_load_cb)
            -- Simulate successful completion
            captured_load_cb(nil, nil)

            assert.is_false(session._loading_saved)
        end)

        it("takes legacy models from the load result", function()
            local session = make_load_session()
            session.config_options = AgentConfigOptions:new(
                function() end,
                function() end,
                function() end,
                function()
                    return true
                end
            )

            session:_do_load_acp_session("test-session-id", "/tmp")
            captured_load_cb({
                models = {
                    availableModels = { { modelId = "m", name = "M" } },
                    currentModelId = "m",
                },
            }, nil)

            assert.equal("m", session.config_options:current_model_id())
        end)

        it("writes nothing after the session is destroyed", function()
            local session = make_load_session()
            local notice_spy = spy.new(function() end)
            session.message_writer.write_notice = notice_spy

            session:_do_load_acp_session("test-session-id", "/tmp")
            session.destroyed = true
            captured_load_cb(nil, nil)

            assert.spy(notice_spy).was.called(0)
        end)

        it("reapplies the saved model after the resume notice", function()
            local session = make_load_session()
            local order = {}
            local notice_spy = spy.new(function()
                table.insert(order, "notice")
            end)
            session.message_writer.write_notice = notice_spy
            session._reapply_model = function(_, model_id)
                table.insert(order, "reapply " .. model_id)
            end

            session:_do_load_acp_session("test-session-id", "/tmp", "saved")
            captured_load_cb(nil, nil)

            assert.same({ "Provider: **Test**" }, notice_spy.calls[1][2].body)
            assert.same({ "notice", "reapply saved" }, order)
        end)

        it("clears _loading_saved on failed load", function()
            local session = make_load_session()
            local notify_stub = spy.stub(Logger, "notify")

            -- Stub _new_session_after_failed_load to avoid side effects
            session._new_session_after_failed_load = function() end

            session:_do_load_acp_session("test-session-id", "/tmp")

            assert.is_not_nil(captured_load_cb)
            -- Simulate failure
            captured_load_cb(nil, { message = "not found" })

            assert.is_false(session._loading_saved)
            notify_stub:revert()
        end)

        -- session_id is assigned before the load RPC, so without this flag the
        -- readiness check reads clear while the session is still replaying.
        it("defers submits for the length of the load", function()
            local session = make_load_session()
            session._prompt_pending = 0
            session.agent.state = "ready"
            session._submit_defer_reason = SessionManager._submit_defer_reason

            session:_do_load_acp_session("test-session-id", "/tmp")

            assert.is_true(session._loading)
            assert.equal("loading", session:_submit_defer_reason("hello"))

            captured_load_cb(nil, nil)

            assert.is_false(session._loading)
            assert.is_nil(session:_submit_defer_reason("hello"))
        end)

        for outcome, err in pairs({
            succeeded = false,
            failed = { message = "x" },
        }) do
            it(
                "ignores a load that /new superseded and that " .. outcome,
                function()
                    local session = make_load_session()
                    --- @type fun(result: table|nil, err: table|nil)|nil
                    local create_cb
                    session.agent.create_session = function(_, _, _, cb)
                        create_cb = cb
                    end
                    session.new_session = SessionManager.new_session
                    session.config_options.set_initial_mode = function() end
                    local fallback = spy.new(function() end)
                    session._new_session_after_failed_load = fallback

                    session:_do_load_acp_session("loaded-sid", "/tmp")
                    local load_cb = captured_load_cb
                    session:new_session({ quiet_welcome = true })
                    assert.is_not_nil(create_cb)
                    --- @cast create_cb fun(result: table|nil, err: table|nil)
                    create_cb({ sessionId = "new-sid" }, nil)
                    session.agent.subscribers["loaded-sid"] = {}
                    --- @cast load_cb fun(result: table|nil, err: table|nil)
                    load_cb(nil, err or nil)

                    assert.equal("new-sid", session.session_id)
                    assert.spy(fallback).was.called(0)
                    if not err then
                        assert.is_nil(session.agent.subscribers["loaded-sid"])
                    end
                end
            )
        end

        it("falls back quietly when the agent cannot load", function()
            local session = make_load_session()
            session.agent.agent_capabilities = { loadSession = false }
            session.agent.load_session = ACPClient.load_session
            session.agent.ERROR_CODES = ACPClient.ERROR_CODES
            local send = spy.new(function() end)
            session.agent._send_request = send
            local read_stub = spy.stub(ChatHistory, "read_saved")
            read_stub:returns({
                session_id = "test-session-id",
                title = "",
                timestamp = 0,
                messages = { { type = "user", text = "hi" } },
            })
            local notify_stub = spy.stub(Logger, "notify")
            local fallback = spy.new(function() end)
            session._new_session_after_failed_load = fallback
            local render = spy.new(function() end)
            session._render_history = render

            session:_do_load_acp_session("test-session-id", "/tmp")
            read_stub:revert()
            notify_stub:revert()

            assert.spy(send).was.called(0)
            assert.spy(notify_stub).was.called(0)
            assert.equal("test-session-id", fallback.calls[1][2])
            assert.equal("hi", fallback.calls[1][3].messages[1].text)
            assert.spy(render).was.called(0)
            assert.is_nil(session._replay_hold)
        end)

        it("clears the load gate when the load fails", function()
            local session = make_load_session()
            local notify_stub = spy.stub(Logger, "notify")
            session._new_session_after_failed_load = function() end

            session:_do_load_acp_session("test-session-id", "/tmp")
            captured_load_cb(nil, { message = "not found" })

            assert.is_false(session._loading)
            notify_stub:revert()
        end)

        -- The success branch is the only drain on this path, and the failure
        -- branch must not also drain — it reaches one via the local-history
        -- fallback, so draining here too would double-send.
        it("drains once on load success and never on failure", function()
            local drains = 0
            local session = make_load_session()
            session._dispatch_deferred_prompts = function()
                drains = drains + 1
            end

            session:_do_load_acp_session("test-session-id", "/tmp")
            captured_load_cb(nil, nil)
            assert.equal(1, drains)

            local notify_stub = spy.stub(Logger, "notify")
            local failed = make_load_session()
            failed._new_session_after_failed_load = function() end
            failed._dispatch_deferred_prompts = function()
                drains = drains + 1
            end

            failed:_do_load_acp_session("test-session-id", "/tmp")
            captured_load_cb(nil, { message = "not found" })

            assert.equal(1, drains)
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
                session.agent.create_session = function(
                    _self,
                    _cwd,
                    _handlers,
                    cb
                )
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

                -- Step 3: load completes, _loading_saved cleared
                assert.is_not_nil(captured_load_cb)
                captured_load_cb(nil, nil) -- success
                assert.is_false(session._loading_saved)

                -- Step 4: stale create_session response arrives AFTER load
                -- This is the race: _loading_saved=false, but epoch mismatch
                captured_create_cb({ sessionId = "stale-new-sid-bbb" }, nil)

                -- session_id must NOT have been overwritten
                assert.equal("loaded-sid-aaa", session.session_id)
                -- stale subscriber should be cleaned up
                assert.is_nil(session.agent.subscribers["stale-new-sid-bbb"])
            end
        )

        it("keeps the create response of a re-create from history", function()
            local session = make_load_session()
            --- @type fun(result: table|nil, err: table|nil)|nil
            local captured_create_cb
            session.agent.create_session = function(_self, _cwd, _handlers, cb)
                captured_create_cb = cb
            end
            session.new_session = SessionManager.new_session
            session.config_options.set_initial_mode = function() end
            session.agent.provider_config = {}
            local created = false

            session:new_session({
                history = ChatHistory:new(),
                quiet_welcome = true,
                on_created = function()
                    created = true
                end,
            })
            assert.is_not_nil(captured_create_cb)
            captured_create_cb({ sessionId = "restored-sid" }, nil)

            assert.equal("restored-sid", session.session_id)
            assert.is_true(created)
        end)

        describe("session cwd after an editor cwd change", function()
            --- @type TestStub
            local getcwd_stub

            --- A session at `/project/a` whose editor has moved to `/project/b`.
            --- @return agentic.SessionManager
            local function moved_session()
                local session = make_load_session()
                session.agent.create_session = function() end
                session.new_session = SessionManager.new_session
                session.restart_session = SessionManager.restart_session
                session._cwd = "/project/a"
                getcwd_stub = spy.stub(vim.fn, "getcwd")
                getcwd_stub:returns("/project/b")
                return session
            end

            after_each(function()
                getcwd_stub:revert()
            end)

            it("new_session takes the editor cwd", function()
                local session = moved_session()
                session:new_session()
                assert.equal("/project/b", session._cwd)
            end)

            it(
                "new_session with a history adopts it and keeps the session cwd",
                function()
                    local session = moved_session()
                    --- @type fun(result: table|nil, err: table|nil)|nil
                    local create_cb
                    session.agent.create_session = function(_, _, _, cb)
                        create_cb = cb
                    end
                    session.config_options.set_initial_mode = function() end
                    session._is_first_message = false
                    local history = ChatHistory:new()
                    history.timestamp = 1
                    history:add_message({ type = "user", text = "hi" })

                    session:new_session({
                        history = history,
                        quiet_welcome = true,
                    })
                    assert.is_not_nil(create_cb)
                    --- @cast create_cb fun(result: table|nil, err: table|nil)
                    create_cb({ sessionId = "new-sid" }, nil)

                    assert.equal(history, session.chat_history)
                    assert.equal("new-sid", history.session_id)
                    assert.are_not.equal(1, history.timestamp)
                    assert.equal(history, session._history_to_send)
                    assert.is_true(session._is_first_message)
                    assert.equal("/project/a", session._cwd)
                end
            )

            it(
                "restart_session with no messages keeps the session cwd",
                function()
                    local session = moved_session()
                    session:restart_session()
                    assert.equal("/project/a", session._cwd)
                end
            )
        end)
    end)

    describe("_replay_entry", function()
        --- A session whose root is `root`, with the file's subagent `c-file`.
        --- @return agentic.SessionManager
        local function make_session()
            return {
                session_id = "root",
                chat_history = { subagents = { ["c-file"] = {} } },
                agent = {
                    subagent_task_id = function(_, update)
                        return update.tag
                    end,
                    is_replay_only_prompt = function(_, text)
                        return text == "summary"
                    end,
                },
                _replay_entry = SessionManager._replay_entry,
            } --[[@as agentic.SessionManager]]
        end

        --- @param text string
        --- @param source string
        --- @return { kind: string, args: table }
        local function user_chunk(text, source)
            return {
                kind = "on_session_update",
                args = {
                    {
                        sessionUpdate = "user_message_chunk",
                        content = { type = "text", text = text },
                    },
                    source,
                },
            }
        end

        it("keys a main prompt, which starts a tail", function()
            assert.same(
                { key = "prompt:go", starts = true },
                make_session():_replay_entry(user_chunk("go", "root"))
            )
        end)

        it("keys a replay-only prompt, which starts no tail", function()
            assert.same(
                { key = "prompt:summary", starts = false },
                make_session():_replay_entry(user_chunk("summary", "root"))
            )
        end)

        it("gives a metadata chunk no key", function()
            assert.same(
                { starts = false },
                make_session():_replay_entry(user_chunk("<env>x</env>", "root"))
            )
        end)

        it("gives a child's prompt no entry, with no agent entry", function()
            assert.is_nil(make_session():_replay_entry(user_chunk("go", "c1")))
        end)

        it("gives a tagged update on the root no entry", function()
            local held = user_chunk("go", "root")
            held.args[1].tag = "toolu_1"
            assert.is_nil(make_session():_replay_entry(held))
        end)

        it("keys a main tool call and a main message row", function()
            local session = make_session()
            assert.same(
                { key = "tool:t1", starts = true },
                session:_replay_entry({
                    kind = "on_tool_call",
                    args = { { tool_call_id = "t1" }, "root" },
                })
            )
            assert.same(
                { key = "message:m1", starts = true },
                session:_replay_entry({
                    kind = "on_session_update",
                    args = {
                        { sessionUpdate = "session_message", messageId = "m1" },
                        "root",
                    },
                })
            )
        end)

        it("gives a subagent's tool call no entry by its tag", function()
            assert.is_nil(make_session():_replay_entry({
                kind = "on_tool_call",
                args = {
                    { tool_call_id = "t1", task_id = "toolu_1" },
                    "root",
                },
            }))
        end)

        it("gives a tool call update and a subagent update no entry", function()
            local session = make_session()
            assert.is_nil(session:_replay_entry({
                kind = "on_tool_call_update",
                args = { { tool_call_id = "t1" }, "root" },
            }))
            assert.is_nil(session:_replay_entry({
                kind = "on_session_update",
                args = {
                    { sessionUpdate = "subagent_update", sessionId = "c9" },
                    "root",
                },
            }))
        end)

        it("gives main agent text an unkeyed entry", function()
            assert.same(
                { starts = false },
                make_session():_replay_entry({
                    kind = "on_session_update",
                    args = {
                        {
                            sessionUpdate = "agent_message_chunk",
                            content = { type = "text", text = "x" },
                        },
                        "root",
                    },
                })
            )
        end)
    end)

    describe("_send_synthetic_prompt", function()
        it("records the prompt as a synthetic user row", function()
            local dispatch = spy.new(function() end)
            local session = {
                chat_history = ChatHistory:new(),
                agent = { provider_config = { name = "Test" } },
                _dispatch_turn = dispatch,
                _history_changed = function() end,
            } --[[@as agentic.SessionManager]]

            SessionManager._send_synthetic_prompt(session, "continue")

            local row = session.chat_history.messages[1]
            assert.equal("continue", row.text)
            assert.is_true(row.synthetic)
            assert.spy(dispatch).was.called(1)
        end)
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

    describe("model announce", function()
        --- @param models table<string, agentic.acp.ConfigOption.Option>
        --- @param current { model_id?: string, thought_level?: string }|nil
        local function make_session(models, current)
            current = current or {}
            local write_spy = spy.new(function() end)
            local notice_spy = spy.new(function() end)
            local session = {
                config_options = {
                    get_model = function(_, id)
                        return models[id]
                    end,
                    current_model_id = function()
                        return current.model_id
                    end,
                    current_thought_level_label = function()
                        return current.thought_level
                    end,
                    legacy_agent_models = {
                        get_model = function() end,
                    },
                    model_display = AgentConfigOptions.model_display,
                    model_title = AgentConfigOptions.model_title,
                },
                message_writer = {
                    write_message = write_spy,
                    write_notice = notice_spy,
                },
                announce_model_loaded = SessionManager.announce_model_loaded,
                _notice_model_switched = SessionManager._notice_model_switched,
            } --[[@as agentic.SessionManager]]
            session.main_view = fake_main_view(session)
            return session, write_spy, notice_spy
        end

        --- @param spy_obj TestSpy
        --- @param call integer
        --- @return string
        local function written_text(spy_obj, call)
            return spy_obj.calls[call][2].content.text
        end

        it("writes bold name · id and description", function()
            local session, write_spy = make_session({
                ["claude-opus-4-8[1m]"] = {
                    value = "claude-opus-4-8[1m]",
                    name = "Opus 4.8 (1M context)",
                    description = "Opus 4.8 with 1M context window.",
                },
            })

            session:announce_model_loaded("claude-opus-4-8[1m]")

            assert.spy(write_spy).was.called(1)
            assert.equal(
                "**Loaded Opus 4.8 (1M context)** · claude-opus-4-8[1m]\n"
                    .. "Opus 4.8 with 1M context window.",
                written_text(write_spy, 1)
            )
        end)

        it("renders an explicit switch as a notice", function()
            local session, write_spy, notice_spy = make_session({
                ["m"] = { value = "m", name = "M", description = "desc" },
            })

            session:_notice_model_switched("m")

            assert.spy(write_spy).was.called(0)
            assert.spy(notice_spy).was.called(1)
            local notice = notice_spy.calls[1][2]
            assert.equal("M · m", notice.title)
            assert.same({ "desc" }, notice.body)
        end)

        it("adds the thought level to a switch notice", function()
            local session, _, notice_spy = make_session(
                { ["m"] = { value = "m", name = "M" } },
                { model_id = "m", thought_level = "Effort: Medium" }
            )

            session:_notice_model_switched("m")

            assert.equal(
                "M · m · Effort: Medium",
                notice_spy.calls[1][2].title
            )
        end)

        it("takes the notice level from the generating state", function()
            local session, _, notice_spy = make_session({
                ["m"] = { value = "m", name = "M" },
            })
            session.is_generating = true

            session:_notice_model_switched("m")

            assert.is_true(notice_spy.calls[1][2].mid_turn)
        end)
    end)

    describe("_reapply_model", function()
        --- @type TestStub
        local notify_stub

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        --- @param current string
        --- @return agentic.acp.ConfigOption
        local function model_option(current)
            --- @type agentic.acp.ConfigOption
            local option = {
                id = "model",
                category = "model",
                currentValue = current,
                description = "",
                name = "Model",
                options = {
                    { value = "a", name = "A" },
                    { value = "b", name = "B" },
                },
            }
            return option
        end

        --- A session whose provider offers models `a` and `b` and runs `a`, or
        --- reports no models yet when `offers_models` is false.
        --- @param offers_models boolean
        --- @return agentic.SessionManager session
        --- @return TestSpy write_spy
        --- @return TestSpy set_option_spy
        local function make_session(offers_models)
            local noop = function() end
            local write_spy = spy.new(noop)
            local set_option_spy = spy.new(noop)
            --- @type agentic.SessionManager
            local session
            local config_options = AgentConfigOptions:new(
                noop,
                function(model_id, is_legacy, opts)
                    session:_handle_model_change(model_id, is_legacy, opts)
                end,
                noop,
                function()
                    return true
                end
            )
            if offers_models then
                config_options:set_options({ model_option("a") })
            end
            session = {
                session_id = "s",
                agent = { set_config_option = set_option_spy },
                config_options = config_options,
                message_writer = { write_message = write_spy },
                render_info = noop,
                _handle_new_config_options = SessionManager._handle_new_config_options,
                announce_model_loaded = SessionManager.announce_model_loaded,
                _reapply_model = SessionManager._reapply_model,
                _handle_model_change = SessionManager._handle_model_change,
                _set_session_option = SessionManager._set_session_option,
            } --[[@as agentic.SessionManager]]
            session.main_view = fake_main_view(session)
            return session, write_spy, set_option_spy
        end

        --- @param write_spy TestSpy
        --- @return string[]
        local function written_texts(write_spy)
            return vim.tbl_map(function(call)
                return call[2].content.text
            end, write_spy.calls)
        end

        it("announces the current model without a saved one", function()
            local session, write_spy, set_option_spy = make_session(true)

            session:_reapply_model(nil)

            assert.same({ "**Loaded A** · a" }, written_texts(write_spy))
            assert.spy(set_option_spy).was.called(0)
        end)

        it("switches to an offered saved model", function()
            local session, write_spy, set_option_spy = make_session(true)

            session:_reapply_model("b")

            assert.same({ "**Loaded A** · a" }, written_texts(write_spy))
            assert.equal("b", set_option_spy.calls[1][4])
        end)

        it("does not switch to the saved model when it is current", function()
            local session, _, set_option_spy = make_session(true)

            session:_reapply_model("a")

            assert.spy(set_option_spy).was.called(0)
        end)

        it("announces the saved model once the switch succeeds", function()
            local session, write_spy, set_option_spy = make_session(true)

            session:_reapply_model("b")
            set_option_spy.calls[1][5]({ configOptions = { model_option("b") } })

            assert.same(
                { "**Loaded A** · a", "**Loaded B** · b" },
                written_texts(write_spy)
            )
        end)

        it("announces no model when the switch fails", function()
            local session, write_spy, set_option_spy = make_session(true)

            session:_reapply_model("b")
            set_option_spy.calls[1][5](nil, { message = "refused" })

            assert.same({ "**Loaded A** · a" }, written_texts(write_spy))
            assert.equal(vim.log.levels.ERROR, notify_stub.calls[1][2])
        end)

        it("warns about a saved model the provider does not offer", function()
            local session, write_spy, set_option_spy = make_session(true)

            session:_reapply_model("gone")

            assert.same({ "**Loaded A** · a" }, written_texts(write_spy))
            assert.spy(set_option_spy).was.called(0)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
            assert.truthy(notify_stub.calls[1][1]:find("gone", 1, true))
        end)

        it("queues the saved model before any model options", function()
            local session, write_spy = make_session(false)

            session:_reapply_model("b")

            assert.spy(write_spy).was.called(0)
            assert.spy(notify_stub).was.called(0)
            assert.equal("b", session.config_options._pending_initial_model)
        end)
    end)

    describe("replace_with_history", function()
        --- @param order string[] Receives the steps in the order they run
        --- @return agentic.SessionManager
        local function make_session(order)
            local noop = function() end
            return {
                clear_chat = noop,
                _install_history = noop,
                new_session = function(_, opts)
                    opts.on_created()
                end,
                _render_history = function()
                    table.insert(order, "render")
                end,
                _reapply_model = function(_, model_id)
                    table.insert(order, "reapply " .. tostring(model_id))
                end,
                replace_with_history = SessionManager.replace_with_history,
            } --[[@as agentic.SessionManager]]
        end

        it("reapplies the history's model after the replay", function()
            local order = {}
            local history = ChatHistory:new()
            history.model = "saved"

            make_session(order):replace_with_history(history)

            assert.same({ "render", "reapply saved" }, order)
        end)

        it("takes a given model over the history's", function()
            local order = {}
            local history = ChatHistory:new()
            history.model = "saved"

            make_session(order):replace_with_history(
                history,
                { model = "live" }
            )

            assert.same({ "render", "reapply live" }, order)
        end)
    end)

    describe("restart_session", function()
        it("re-creates the session on its live model", function()
            local history = ChatHistory:new()
            history:add_message({ type = "user", text = "hi" })
            history.model = "saved"
            local replace_spy = spy.new(function() end)
            local session = {
                chat_history = history,
                config_options = {
                    current_model_id = function()
                        return "live"
                    end,
                },
                _cancel_session = function() end,
                replace_with_history = replace_spy,
                restart_session = SessionManager.restart_session,
            } --[[@as agentic.SessionManager]]

            session:restart_session()

            assert.same({ model = "live" }, replace_spy.calls[1][3])
        end)
    end)

    describe("_handle_mode_change", function()
        --- @type TestStub
        local notify_stub

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        --- @param err table|nil Error the provider answers `session/set_mode` with
        local function make_session(err)
            local legacy_modes = AgentModes:new()
            legacy_modes:set_modes({
                availableModes = {
                    { id = "plan", name = "Plan", description = "Planning" },
                    { id = "auto", name = "Auto", description = "No prompts" },
                },
                currentModeId = "plan",
            })
            local notice_spy = spy.new(function() end)
            local session = {
                session_id = "s",
                agent = {
                    set_mode = function(_, _session_id, _mode_id, callback)
                        callback({}, err)
                    end,
                },
                config_options = {
                    legacy_agent_modes = legacy_modes,
                    get_mode = function() end,
                },
                message_writer = { write_notice = notice_spy },
                _update_chat_header = function() end,
                _handle_mode_change = SessionManager._handle_mode_change,
                _set_session_option = SessionManager._set_session_option,
                render_info = function() end,
                _notice_mode_switched = SessionManager._notice_mode_switched,
            } --[[@as agentic.SessionManager]]
            return session, notice_spy
        end

        it("renders a picked mode as a notice", function()
            local session, notice_spy = make_session(nil)

            session:_handle_mode_change("auto", true, { as_notice = true })

            assert.spy(notice_spy).was.called(1)
            local notice = notice_spy.calls[1][2]
            assert.equal(Glyphs.KIND.switch_mode, notice.glyph)
            assert.equal("Auto", notice.title)
            assert.same({ "No prompts" }, notice.body)
            assert.spy(notify_stub).was.called(0)
        end)

        it("stays silent for a change the user did not pick", function()
            local session, notice_spy = make_session(nil)

            session:_handle_mode_change("auto", true)

            assert.equal(
                "auto",
                session.config_options.legacy_agent_modes.current_mode_id
            )
            assert.spy(notice_spy).was.called(0)
            assert.spy(notify_stub).was.called(0)
        end)

        it("renders the info panel once the mode is set", function()
            local session = make_session(nil)
            local mode_at_render
            session.render_info = function(this)
                mode_at_render =
                    this.config_options.legacy_agent_modes.current_mode_id
            end

            session:_handle_mode_change("auto", true)

            assert.equal("auto", mode_at_render)
        end)

        it("drops the response of a session destroyed meanwhile", function()
            local session, notice_spy = make_session(nil)
            local render_spy = spy.new(function() end)
            session.render_info = render_spy --[[@as function]]
            session.destroyed = true

            session:_handle_mode_change("auto", true, { as_notice = true })

            assert.equal(
                "plan",
                session.config_options.legacy_agent_modes.current_mode_id
            )
            assert.spy(notice_spy).was.called(0)
            assert.spy(render_spy).was.called(0)
        end)

        it("reports a failed change as an error, not a notice", function()
            local session, notice_spy = make_session({ message = "nope" })

            session:_handle_mode_change("auto", true, { as_notice = true })

            assert.spy(notice_spy).was.called(0)
            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.ERROR, notify_stub.calls[1][2])
        end)

        it("keeps a legacy mode id past the returned options", function()
            local session = make_session(nil)
            local legacy_modes = session.config_options.legacy_agent_modes
            session.agent.set_mode = function(
                _,
                _session_id,
                _mode_id,
                callback
            )
                callback({ configOptions = {} }, nil)
            end
            -- As `set_options`, which clears the legacy state.
            session._handle_new_config_options = function()
                legacy_modes:clear()
            end

            session:_handle_mode_change("auto", true)

            assert.equal("auto", legacy_modes.current_mode_id)
        end)

        it("leaves the legacy mode id on a config option change", function()
            local session = make_session(nil)
            session.config_options.mode = { id = "mode" }
            session.agent.set_config_option = function(_, _sid, _id, _v, cb)
                cb({}, nil)
            end

            session:_handle_mode_change("auto", false)

            assert.equal(
                "plan",
                session.config_options.legacy_agent_modes.current_mode_id
            )
        end)
    end)

    describe("_set_session_option", function()
        local function make_session()
            local set_spy = spy.new(function() end)
            local session = {
                session_id = "s",
                agent = { set_config_option = set_spy },
                config_options = {
                    mode = { id = "mode-id" },
                    thought_level = { id = "effort" },
                },
                _set_session_option = SessionManager._set_session_option,
            } --[[@as agentic.SessionManager]]
            return session, set_spy
        end

        it("sends the option's id, not its category", function()
            local session, set_spy = make_session()

            session:_set_session_option(
                "thought_level",
                "high",
                false,
                function() end
            )
            session:_set_session_option("mode", "plan", false, function() end)

            assert.equal("effort", set_spy.calls[1][3])
            assert.equal("mode-id", set_spy.calls[2][3])
        end)

        it("reports an option the provider no longer offers", function()
            local session, set_spy = make_session()
            session.config_options.thought_level = nil
            local notify_stub = spy.stub(Logger, "notify")
            MiniTest.finally(function()
                notify_stub:revert()
            end)

            session:_set_session_option(
                "thought_level",
                "high",
                false,
                function() end
            )

            assert.spy(set_spy).was.called(0)
            assert.equal(vim.log.levels.ERROR, notify_stub.calls[1][2])
        end)
    end)

    describe("_handle_thought_level_change", function()
        local function make_session()
            local config_options = AgentConfigOptions:new(
                function() end,
                function() end,
                function() end,
                function()
                    return true
                end
            )
            --- @param level string
            --- @return agentic.acp.ConfigOption[]
            local function options_at(level)
                return {
                    {
                        id = "effort",
                        category = "thought_level",
                        currentValue = level,
                        name = "Effort",
                        options = {
                            { value = "low", name = "Low" },
                            { value = "high", name = "High" },
                        },
                    },
                }
            end
            config_options:set_options(options_at("low"))
            local notice_spy = spy.new(function() end)
            local session = {
                session_id = "s",
                agent = {
                    set_config_option = function(_, _sid, _id, value, cb)
                        cb({ configOptions = options_at(value) }, nil)
                    end,
                },
                config_options = config_options,
                message_writer = { write_notice = notice_spy },
                _handle_new_config_options = function(this, options)
                    this.config_options:set_options(options)
                end,
                render_info = function() end,
                _set_session_option = SessionManager._set_session_option,
                _handle_thought_level_change = SessionManager._handle_thought_level_change,
                _notice_thought_level_switched = SessionManager._notice_thought_level_switched,
            } --[[@as agentic.SessionManager]]
            return session, notice_spy
        end

        it("notices the level from the reply's options", function()
            local session, notice_spy = make_session()

            session:_handle_thought_level_change("high", { as_notice = true })

            assert.spy(notice_spy).was.called(1)
            local notice = notice_spy.calls[1][2]
            assert.equal(Glyphs.COMMAND.effort, notice.glyph)
            assert.equal("Effort: High", notice.title)
        end)

        it("writes no notice without as_notice", function()
            local session, notice_spy = make_session()

            session:_handle_thought_level_change("high")

            assert.spy(notice_spy).was.called(0)
        end)
    end)

    describe("_handle_model_change", function()
        it("records a legacy model change as the current model", function()
            local AgentModels = require("agentic.acp.agent_models")
            local legacy_models = AgentModels:new()
            legacy_models.current_model_id = "old"
            local session = {
                session_id = "s",
                agent = {
                    set_model = function(_, _session_id, _model_id, callback)
                        callback({}, nil)
                    end,
                },
                config_options = {
                    legacy_agent_models = legacy_models,
                    current_model_id = AgentConfigOptions.current_model_id,
                },
                announce_model_loaded = function() end,
                _handle_model_change = SessionManager._handle_model_change,
                _set_session_option = SessionManager._set_session_option,
                render_info = function() end,
            } --[[@as agentic.SessionManager]]

            session:_handle_model_change("new", true)

            assert.equal("new", session.config_options:current_model_id())
        end)
    end)

    describe("_display_context_usage", function()
        --- @param usage table|nil
        --- @return agentic.ui.MessageWriter.Notice
        local function notice_for(usage)
            local captured
            local session = {
                _usage = usage,
                message_writer = {
                    write_notice = function(_, notice)
                        captured = notice
                    end,
                },
                _display_context_usage = SessionManager._display_context_usage,
            } --[[@as agentic.SessionManager]]

            session:_display_context_usage()
            return captured
        end

        it("titles with the totals and bodies the cost", function()
            local notice = notice_for({
                used = 72400,
                size = 200000,
                cost = { amount = 0.0412, currency = "USD" },
            })

            assert.equal("72.4k / 200k tokens (36%)", notice.title)
            assert.same({ "- Cost: 0.0412 USD" }, notice.body)
        end)

        it("falls back to a bare title with no totals to show", function()
            local notice = notice_for(nil)

            assert.equal("context", notice.title)
            assert.same({ "No usage data available yet." }, notice.body)
        end)

        it("omits the cost when the provider reported none", function()
            local notice = notice_for({ used = 1000, size = 200000 })

            assert.same({}, notice.body)
        end)

        it("keeps a cost figure away from the no-data line", function()
            -- size 0 means no totals; a spend figure under "no usage data"
            -- would contradict the line above it.
            local notice = notice_for({
                used = 0,
                size = 0,
                cost = { amount = 1, currency = "USD" },
            })

            assert.same({ "No usage data available yet." }, notice.body)
        end)
    end)

    describe("render_info", function()
        it("renders the snapshot and fits the panel", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            MiniTest.finally(function()
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end)
            local resize_spy = spy.new(function() end)
            local session = {
                agent = {
                    provider_config = { name = "Claude" },
                    auth_status = { kind = "none", label = "None" },
                },
                config_options = {
                    current_model_id = function()
                        return nil
                    end,
                    current_mode_id = function()
                        return nil
                    end,
                    current_thought_level_label = function()
                        return nil
                    end,
                },
                widget = {
                    panel_buf = function()
                        return bufnr
                    end,
                    resize_panel = resize_spy,
                },
                _info_snapshot = SessionManager._info_snapshot,
                render_info = SessionManager.render_info,
            } --[[@as agentic.SessionManager]]

            session:render_info()

            assert.same(
                { "- Agent: Claude", "- Account: not logged in" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            assert.spy(resize_spy).was.called(1)
            assert.equal("info", resize_spy.calls[1][2])
        end)

        it("does nothing without an info buffer", function()
            local resize_spy = spy.new(function() end)
            local session = {
                widget = {
                    panel_buf = function()
                        return nil
                    end,
                    resize_panel = resize_spy,
                },
                render_info = SessionManager.render_info,
            } --[[@as agentic.SessionManager]]

            session:render_info()

            assert.spy(resize_spy).was.called(0)
        end)
    end)

    describe("switch_provider", function()
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local schedule_stub

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
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

            session:switch_provider("new-provider")

            assert.spy(notify_stub).was.called(1)
            local msg = notify_stub.calls[1][1]
            assert.truthy(msg:match("[Gg]enerating"))
        end)

        it(
            "soft cancels old session without clearing widget/history",
            function()
                local cancel_spy = spy.new(function() end)
                local perm_cancel_spy = spy.new(function() end)
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
                local default_provider = Config.provider

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = cancel_spy,
                        provider_config = { name = "Old Provider" },
                    },
                    permission_manager = {
                        cancel_requests = perm_cancel_spy,
                    },
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

                session:switch_provider("new-provider")

                assert.equal("new-provider", get_instance_stub.calls[1][1])
                assert.equal(default_provider, Config.provider)
                assert.spy(cancel_spy).was.called(1)
                assert.is_nil(session.session_id)
                assert.spy(perm_cancel_spy).was.called(1)
                assert.spy(todo_clear_spy).was.called(1)

                assert.spy(widget_clear_spy).was.called(0)
                assert.spy(file_list_clear_spy).was.called(0)
                assert.spy(code_selection_clear_spy).was.called(0)

                assert.equal(mock_new_agent, session.agent)

                assert.spy(new_session_spy).was.called(1)
                local opts = new_session_spy.calls[1][2]
                assert.equal(mock_chat_history, opts.history)
                assert.equal("function", type(opts.on_created))
            end
        )

        it("passes the history to new_session", function()
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
            local saved_history = {
                messages = { { type = "user", text = "hello" } },
                session_id = "old",
            }
            local write_notice = spy.new(function() end)

            local session = {
                is_generating = false,
                session_id = "old-session",

                agent = {
                    cancel_session = spy.new(function() end),
                    provider_config = { name = "Old" },
                },
                permission_manager = {
                    cancel_requests = function() end,
                },
                todo_list = { clear = function() end },
                message_writer = { write_notice = write_notice },
                chat_history = saved_history,
                config_options = { current_model_id = function() end },
                announce_model_loaded = function() end,
                new_session = new_session_spy,
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider("new-provider")

            local opts = new_session_spy.calls[1][2]
            assert.equal(saved_history, opts.history)
            opts.on_created()
            assert.equal("New Provider", write_notice.calls[1][2].title)
        end)

        -- A usage limit is the main reason to switch provider at all. Carrying
        -- the outgoing provider's reset time over would defer every submit to
        -- the new one until it elapsed.
        it("opens the usage gate for the new provider", function()
            local AgentInstance = require("agentic.acp.agent_instance")
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(_provider, on_ready)
                local agent = {
                    provider_config = { name = "New" },
                    create_session = spy.new(function() end),
                }
                on_ready(agent)
                return agent
            end)

            local session = {
                is_generating = false,
                session_id = "old-session",
                _usage_reset_epoch = os.time() + 3600,
                agent = {
                    cancel_session = spy.new(function() end),
                    provider_config = { name = "Old" },
                },
                permission_manager = {
                    cancel_requests = function() end,
                },
                todo_list = { clear = function() end },
                message_writer = { write_notice = spy.new(function() end) },
                chat_history = { messages = {}, session_id = "old" },
                _is_first_message = false,
                _history_to_send = nil,
                new_session = spy.new(function() end),
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider("new-provider")

            assert.is_nil(session._usage_reset_epoch)
        end)

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

            local session = {
                is_generating = false,
                session_id = nil,

                agent = mock_agent,
                permission_manager = {
                    cancel_requests = spy.new(function() end),
                },
                todo_list = { clear = spy.new(function() end) },
                chat_history = { messages = {} },
                _is_first_message = false,
                _history_to_send = nil,
                new_session = spy.new(function() end),
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider("some-provider")

            assert.spy(mock_agent.cancel_session).was.called(0)
            assert.spy(session.permission_manager.cancel_requests).was.called(1)
            assert.spy(session.todo_list.clear).was.called(1)
            assert.spy(session.new_session).was.called(1)
        end)

        it("names the new provider, then its model, from on_created", function()
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
            local order = {}
            local notice_spy = spy.new(function()
                table.insert(order, "notice")
            end)
            local session = {
                is_generating = false,
                session_id = "old-session",
                agent = {
                    cancel_session = spy.new(function() end),
                    provider_config = { name = "Old" },
                },
                permission_manager = {
                    cancel_requests = function() end,
                },
                todo_list = { clear = function() end },
                message_writer = { write_notice = notice_spy },
                widget = { buf_nrs = {} },
                chat_history = { messages = {}, session_id = "old" },
                config_options = {
                    current_model_id = function()
                        return "m"
                    end,
                },
                announce_model_loaded = function(_, model_id)
                    table.insert(order, "announce " .. model_id)
                end,
                new_session = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end),
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)

            session:switch_provider("new-provider")
            captured_on_created()

            assert.equal("New Provider", notice_spy.calls[1][2].title)
            assert.same({ "notice", "announce m" }, order)
        end)
    end)

    describe("on_tool_call_update: buffer reload", function()
        --- @type TestStub
        local checktime_stub
        --- @type TestStub
        local schedule_stub

        --- @param tool_call_blocks table<string, table>
        --- @return agentic.SessionManager
        --- @return { n: integer, subagents: string[] } drains counted, and the subagents drained
        local function make_session(tool_call_blocks)
            local drains = { n = 0, subagents = {} }
            --- @type agentic.SessionManager
            local session = {
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
                _record_file_op = function() end,
                status_indicator = {
                    start = function() end,
                    reposition = function() end,
                },
                chat_history = { update_tool_call = function() end },
                _history_changed = function() end,
                _view_for = SessionManager._view_for,
                _drain_side_records = function()
                    drains.n = drains.n + 1
                end,
                _drain_subagent_side_records = function(_self, child_id)
                    table.insert(drains.subagents, child_id)
                end,
                _drain_side_records_of = SessionManager._drain_side_records_of,
                _sync_output_tail = SessionManager._sync_output_tail,
                _sync_job_stop = SessionManager._sync_job_stop,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            session._subagents.read_record = function() end
            session._subagents.transcript = function()
                return {
                    view = {
                        writer = {
                            update_tool_call_block = function() end,
                            tool_call_blocks = tool_call_blocks,
                        },
                        status_indicator = {
                            reposition = function() end,
                            switch = function() end,
                        },
                    },
                }
            end
            return session, drains
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

        it("drains hook records on a terminal update", function()
            for _, status in ipairs({ "completed", "failed" }) do
                local session, drains =
                    make_session({ ["tc-1"] = { kind = "read" } })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = "tc-1", status = status }
                )

                assert.equal(1, drains.n)
            end
        end)

        it("does not drain before the call is terminal", function()
            local session, drains =
                make_session({ ["tc-1"] = { kind = "read" } })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "in_progress" }
            )

            assert.equal(0, drains.n)
        end)

        it("drains the subagent's records for its tool call", function()
            local session, drains =
                make_session({ ["tc-1"] = { kind = "read" } })
            session._subagents._tool_call_owner["tc-1"] = "task-1"

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "completed" }
            )

            assert.equal(0, drains.n)
            assert.same({ "task-1" }, drains.subagents)
        end)
    end)

    describe("plan exit", function()
        -- The option is offered off the tracker, never off the permission
        -- request.
        local PLAN_EXIT_BLOCK =
            { kind = "switch_mode", argument = "Normal", exits_plan = true }

        --- @param block table|nil Tracker for the requesting tool call
        --- @param new_session fun()|nil Stub for `session.new_session`
        --- @param plan_file string|nil The plan file the request names
        --- @return agentic.acp.RequestPermission request as add_request saw it
        --- @return fun(option_id: string) choose What a pick in the prompt calls
        --- @return agentic.SessionManager session
        local function request_for(block, new_session, plan_file)
            --- @type agentic.acp.RequestPermission
            local seen
            --- @type fun(option_id: string)
            local choose
            --- @type agentic.SessionManager
            local session = {
                status_indicator = { stop = function() end },
                message_writer = { tool_call_blocks = { ["tc-plan"] = block } },
                agent = {
                    plan_file = function(_self, request)
                        return request.toolCall.rawInput.planFilePath
                    end,
                },
                _last_edited_md = "/project/plan.md",
                _view_for = SessionManager._view_for,
                _handle_input_submit = spy.new(function() end),
                new_session = new_session,
                permission_manager = {
                    add_request = function(_self, request, callback)
                        seen = request
                        choose = callback
                        return false
                    end,
                },
            } --[[@as agentic.SessionManager]]
            with_subagents(session)

            SessionManager._on_request_permission(session, {
                sessionId = "s-1",
                toolCall = {
                    toolCallId = "tc-plan",
                    kind = "switch_mode",
                    rawInput = { planFilePath = plan_file },
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Yes",
                        kind = "allow_once",
                    },
                },
            }, function() end)

            return seen, choose, session
        end

        --- Pick the plan-implement option and run the fresh session's
        --- `on_created`.
        --- @param plan_file string|nil
        --- @return string|nil prompt What the fresh session was sent
        local function implement(plan_file)
            local new_session = spy.new(function() end)
            local request, choose, session =
                request_for(PLAN_EXIT_BLOCK, new_session, plan_file)
            local deferred = Deferred.capture()
            choose(request.options[2].optionId)
            deferred.drain()
            deferred.revert()

            new_session.calls[1][2].on_created()
            local submit = session._handle_input_submit --[[@as TestSpy]]
            return submit.calls[1] and submit.calls[1][2]
        end

        it("offers to clear context and implement the plan", function()
            local options = request_for(PLAN_EXIT_BLOCK).options

            assert.equal(2, #options)
            assert.equal("plan_implement", options[2].kind)
        end)

        it("implements the plan in the session's cwd", function()
            local new_session = spy.new(function() end)
            local request, choose = request_for(PLAN_EXIT_BLOCK, new_session)
            local deferred = Deferred.capture()

            choose(request.options[2].optionId)
            deferred.drain()
            deferred.revert()

            assert.is_true(new_session.calls[1][2].keep_cwd)
        end)

        it("uses the plan file the agent reports", function()
            assert.equal(
                "Initiate work on plan: /plans/agent.md",
                implement("/plans/agent.md")
            )
        end)

        it("falls back to the last edited markdown file", function()
            assert.equal(
                "Initiate work on plan: /project/plan.md",
                implement(nil)
            )
        end)

        it("leaves other tool calls' options alone", function()
            local options = request_for({ kind = "edit" }).options

            assert.equal(1, #options)
        end)

        it("leaves a switch_mode call without exits_plan alone", function()
            local options = request_for({
                kind = "switch_mode",
                argument = "Normal",
            }).options

            assert.equal(1, #options)
        end)
    end)

    describe("_drain_subagent_side_records", function()
        it("applies only tool call fields, to the subagent's call", function()
            local drained_with
            local child_writer = {
                tool_call_blocks = { ["toolu_send"] = { status = "completed" } },
                update_tool_call_block = spy.new(function() end),
            }
            --- @type agentic.SessionManager
            local session = {
                destroyed = false,
                session_id = "s-1",
                _held_tool_call_updates = {},
                _drain_subagent_side_records = SessionManager._drain_subagent_side_records,
                _apply_side_tool_call = SessionManager._apply_side_tool_call,
                _view_for = function()
                    return { writer = child_writer }
                end,
                _history_changed = function() end,
                chat_history = { update_tool_call = function() end },
                agent = {
                    drain_side_records = function(_self, session_id, child_id)
                        drained_with = { session_id, child_id }
                        return {
                            {
                                kind = "tool_call",
                                tool_call = {
                                    tool_call_id = "toolu_send",
                                    argument = "main",
                                },
                            },
                            {
                                kind = "hook",
                                hook = { group = "context", body = { "x" } },
                            },
                        }
                    end,
                },
                -- A write here would put the subagent's record in the main chat.
                message_writer = {},
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            session._subagents._tool_call_owner["toolu_send"] = "a1"

            session:_drain_subagent_side_records("a1")

            assert.same({ "s-1", "a1" }, drained_with)
            assert.equal(1, child_writer.update_tool_call_block.call_count)
            assert.equal(
                "main",
                child_writer.update_tool_call_block.calls[1][2].argument
            )
        end)
    end)

    describe("_drain_side_records", function()
        --- @param records table[] hook records, or side records as they are
        --- @return agentic.SessionManager
        --- @return agentic.ui.MessageWriter.HookBlock[] written one per write_hook_block call
        --- @return agentic.acp.LoadedFile[] loaded one per write_loaded_file call
        --- @return agentic.ui.MessageWriter.HookRow[] rows one per write_hook_row call
        --- @return string[] calls the writer methods called, in order
        --- @return agentic.acp.DiscoveredSkills[] skills one per write_discovered_skills call
        local function make_session(records)
            local sides = vim.tbl_map(function(record)
                return record.kind and record
                    or { kind = "hook", hook = record }
            end, records)
            local written, loaded, rows, calls, skills = {}, {}, {}, {}, {}
            --- @param list table[]
            --- @param method string
            --- @return fun(self: table, arg: table)
            local function record_into(list, method)
                return function(_self, arg)
                    table.insert(list, arg)
                    table.insert(calls, method)
                end
            end
            --- @type agentic.SessionManager
            local session = {
                destroyed = false,
                session_id = "s-1",
                _drain_side_records = SessionManager._drain_side_records,
                _block_id = SessionManager._block_id,
                _apply_side_tool_call = function()
                    table.insert(calls, "_apply_side_tool_call")
                end,
                _history_changed = function()
                    table.insert(calls, "_history_changed")
                end,
                chat_history = ChatHistory:new(),
                agent = {
                    drain_side_records = function()
                        return sides
                    end,
                },
                message_writer = {
                    tool_call_blocks = {},
                    write_hook_block = record_into(written, "write_hook_block"),
                    write_hook_row = record_into(rows, "write_hook_row"),
                    write_loaded_file = record_into(
                        loaded,
                        "write_loaded_file"
                    ),
                    write_discovered_skills = record_into(
                        skills,
                        "write_discovered_skills"
                    ),
                },
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            session._subagents.read_record = function() end
            session._subagents.write_received_message = function(_self, message)
                table.insert(calls, "write_received_message")
                session.chat_history:add_message({
                    type = "session_message",
                    message_id = message.message_id,
                })
            end
            return session, written, loaded, rows, calls, skills
        end

        it("keeps its written records as one history message", function()
            local hook = { group = "context", body = { "ctx" } }
            local file = { path = "/r/a.md" }
            local session, _, _, _, calls = make_session({
                hook,
                { kind = "tool_call", tool_call = { tool_call_id = "t1" } },
                { kind = "loaded_file", loaded_file = file },
            })

            session:_drain_side_records()

            assert.same({
                {
                    type = "side_records",
                    records = {
                        { kind = "hook", hook = hook },
                        { kind = "loaded_file", loaded_file = file },
                    },
                },
            }, session.chat_history.messages)
            assert.same({
                "_apply_side_tool_call",
                "write_hook_block",
                "write_loaded_file",
                "_history_changed",
            }, calls)
        end)

        it("keeps the records around a received message in order", function()
            local before = { path = "/r/before.md" }
            local after = { path = "/r/after.md" }
            local session, _, _, _, calls = make_session({
                { kind = "loaded_file", loaded_file = before },
                {
                    kind = "received_message",
                    received_message = { message_id = "m1", text = "hi" },
                },
                { kind = "loaded_file", loaded_file = after },
            })

            session:_drain_side_records()

            assert.same({
                {
                    type = "side_records",
                    records = { { kind = "loaded_file", loaded_file = before } },
                },
                { type = "session_message", message_id = "m1" },
                {
                    type = "side_records",
                    records = { { kind = "loaded_file", loaded_file = after } },
                },
            }, session.chat_history.messages)
            assert.same({
                "write_loaded_file",
                "write_received_message",
                "write_loaded_file",
                "_history_changed",
            }, calls)
        end)

        it("keeps nothing without a written record", function()
            local session, _, _, _, calls = make_session({
                { kind = "tool_call", tool_call = { tool_call_id = "t1" } },
            })

            session:_drain_side_records()

            assert.same({}, session.chat_history.messages)
            assert.same({ "_apply_side_tool_call" }, calls)
        end)

        it("keeps the subagent block a record was mapped to", function()
            local session = make_session({
                {
                    group = "context",
                    body = { "ctx" },
                    tool_call_id = "toolu_1",
                },
            })
            session._subagents._agent_by_task.toolu_1 = "child-1"

            session:_drain_side_records()

            local stored = session.chat_history.messages[1].records[1]
            assert.equal("child-1", stored.hook.tool_call_id)
        end)

        describe(
            "a record naming a call that delegated to a subagent",
            function()
                --- A context record, a pass, a loaded file and discovered
                --- skills, all naming `id`.
                --- @param id string
                --- @return table[]
                local function records_naming(id)
                    return {
                        {
                            group = "context",
                            body = { "ctx" },
                            tool_call_id = id,
                        },
                        { group = "passed", body = {}, tool_call_id = id },
                        {
                            kind = "loaded_file",
                            loaded_file = {
                                path = "/r/a.md",
                                tool_call_id = id,
                            },
                        },
                        {
                            kind = "discovered_skills",
                            discovered_skills = {
                                title = "New skills",
                                body = { "- foo" },
                                tool_call_id = id,
                            },
                        },
                    }
                end

                it("goes under the subagent's block", function()
                    local session, written, loaded, rows, _, skills =
                        make_session(records_naming("toolu_1"))
                    session._subagents._agent_by_task.toolu_1 = "child-1"

                    session:_drain_side_records()

                    assert.equal("child-1", written[1].tool_call_id)
                    assert.equal("child-1", loaded[1].tool_call_id)
                    assert.equal("child-1", rows[1].tool_call_id)
                    assert.equal("child-1", skills[1].tool_call_id)
                end)

                it(
                    "keeps its id when the call has a block of its own",
                    function()
                        local session, written, loaded, rows, _, skills =
                            make_session(records_naming("toolu_1"))
                        session._subagents._agent_by_task.toolu_1 = "child-1"
                        session.message_writer.tool_call_blocks.toolu_1 = {}

                        session:_drain_side_records()

                        assert.equal("toolu_1", written[1].tool_call_id)
                        assert.equal("toolu_1", loaded[1].tool_call_id)
                        assert.equal("toolu_1", rows[1].tool_call_id)
                        assert.equal("toolu_1", skills[1].tool_call_id)
                    end
                )

                it("keeps an id no subagent is linked to", function()
                    local session, written, loaded, rows =
                        make_session(records_naming("toolu_1"))

                    session:_drain_side_records()

                    assert.equal("toolu_1", written[1].tool_call_id)
                    assert.equal("toolu_1", loaded[1].tool_call_id)
                    assert.equal("toolu_1", rows[1].tool_call_id)
                end)

                it("reads every subagent's record before mapping", function()
                    local session, written =
                        make_session(records_naming("toolu_1"))
                    session._subagents._agents =
                        { ["child-1"] = {}, ["child-2"] = {} }
                    local read = {}
                    session._subagents.read_record = function(self, child_id)
                        table.insert(read, child_id)
                        if child_id == "child-1" then
                            self._agent_by_task.toolu_1 = child_id
                        end
                    end

                    session:_drain_side_records()

                    table.sort(read)
                    assert.same({ "child-1", "child-2" }, read)
                    assert.equal("child-1", written[1].tool_call_id)
                end)

                --- How many subagent records a drain reads once `change` is
                --- applied to the session.
                --- @param change fun(session: agentic.SessionManager)
                --- @return integer
                local function reads_after(change)
                    local session = make_session(records_naming("toolu_1"))
                    session._subagents._agents = { ["child-1"] = {} }
                    change(session)
                    local reads = 0
                    session._subagents.read_record = function()
                        reads = reads + 1
                    end
                    session:_drain_side_records()
                    return reads
                end

                it("reads no record once the session is destroyed", function()
                    assert.equal(
                        0,
                        reads_after(function(session)
                            session.destroyed = true
                        end)
                    )
                end)

                it("reads no record without a session", function()
                    assert.equal(
                        0,
                        reads_after(function(session)
                            session.session_id = nil
                        end)
                    )
                end)
            end
        )

        it("writes nothing once the session is destroyed", function()
            local session, written =
                make_session({ { group = "context", body = { "ctx" } } })
            session.destroyed = true

            session:_drain_side_records()

            assert.same({}, written)
        end)

        it("writes nothing without a session", function()
            local session, written =
                make_session({ { group = "context", body = { "ctx" } } })
            session.session_id = nil

            session:_drain_side_records()

            assert.same({}, written)
        end)
    end)

    describe("_record_file_op", function()
        --- @param tracker table|nil MessageWriter tracker for "tc-1"
        --- @return agentic.SessionManager
        --- @return table[] recorded
        local function make_session(tracker)
            --- @type table[]
            local recorded = {}
            --- @type agentic.SessionManager
            local session = {
                message_writer = {
                    tool_call_blocks = tracker and { ["tc-1"] = tracker } or {},
                },
                file_activity = {
                    record = function(_self, op)
                        table.insert(recorded, op)
                        return true
                    end,
                },
                _view_for = SessionManager._view_for,
                _record_file_op = SessionManager._record_file_op,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            return session, recorded
        end

        it("records a completed edit against the tracker's path", function()
            local session, recorded = make_session({
                kind = "edit",
                status = "completed",
                argument = "/repo/a.lua",
                diff = { old = { "before" }, new = { "after" } },
            })

            session:_record_file_op("tc-1")

            assert.equal(1, #recorded)
            assert.equal("/repo/a.lua", recorded[1].path)
            assert.equal("edit", recorded[1].op)
            assert.equal("tc-1", recorded[1].tool_call_id)
        end)

        it("prefers the provider's own created-or-not answer", function()
            -- A whole-file write over an existing file: the diff has no old
            -- side, so only file_created distinguishes it from a creation.
            local session, recorded = make_session({
                kind = "edit",
                status = "completed",
                argument = "/repo/a.lua",
                file_created = false,
                diff = { old = {}, new = { "whole file" } },
            })

            session:_record_file_op("tc-1")

            assert.equal("edit", recorded[1].op)
        end)

        it("falls back to an empty diff old side meaning creation", function()
            local session, recorded = make_session({
                kind = "edit",
                status = "completed",
                argument = "/repo/new.lua",
                diff = { old = {}, new = { "hello" } },
            })

            session:_record_file_op("tc-1")

            assert.equal("create", recorded[1].op)
        end)

        it("records a delete kind as a deletion", function()
            local session, recorded = make_session({
                kind = "delete",
                status = "completed",
                argument = "/repo/a.lua",
            })

            session:_record_file_op("tc-1")

            assert.equal("delete", recorded[1].op)
        end)

        it("carries the provider's hunk ranges through", function()
            local session, recorded = make_session({
                kind = "edit",
                status = "completed",
                argument = "/repo/a.lua",
                diff = { old = { "x" }, new = { "y" } },
                hunk_ranges = { { start_line = 9, end_line = 11 } },
            })

            session:_record_file_op("tc-1")

            assert.same(
                { { start_line = 9, end_line = 11 } },
                recorded[1].ranges
            )
        end)

        it("lowercases the kind before dispatching", function()
            -- opencode capitalises kinds; display_kind hides the difference.
            local session, recorded = make_session({
                kind = "Edit",
                status = "completed",
                argument = "/repo/a.lua",
                diff = { old = { "x" }, new = { "y" } },
            })

            session:_record_file_op("tc-1")

            assert.equal(1, #recorded)
        end)

        it("ignores a call that has not finished", function()
            local session, recorded = make_session({
                kind = "edit",
                status = "in_progress",
                argument = "/repo/a.lua",
            })

            session:_record_file_op("tc-1")

            assert.equal(0, #recorded)
        end)

        it("ignores a failed call, which includes a rejected prompt", function()
            local session, recorded = make_session({
                kind = "edit",
                status = "failed",
                argument = "/repo/a.lua",
            })

            session:_record_file_op("tc-1")

            assert.equal(0, #recorded)
        end)

        it("ignores non-mutating kinds", function()
            for _, kind in ipairs({ "read", "search", "execute", "fetch" }) do
                local session, recorded = make_session({
                    kind = kind,
                    status = "completed",
                    argument = "/repo/a.lua",
                })

                session:_record_file_op("tc-1")

                assert.equal(0, #recorded)
            end
        end)

        it("ignores a mutation with no path", function()
            local session, recorded = make_session({
                kind = "edit",
                status = "completed",
                argument = "",
            })

            session:_record_file_op("tc-1")

            assert.equal(0, #recorded)
        end)

        it("ignores an unknown tool call", function()
            local session, recorded = make_session(nil)

            session:_record_file_op("tc-1")

            assert.equal(0, #recorded)
        end)

        it("does nothing while tracking is disabled", function()
            local original = Config.windows.activity
            Config.windows.activity =
                vim.tbl_extend("force", original, { display = false })

            local session, recorded = make_session({
                kind = "edit",
                status = "completed",
                argument = "/repo/a.lua",
                diff = { old = { "x" }, new = { "y" } },
            })

            session:_record_file_op("tc-1")

            assert.equal(0, #recorded)
            Config.windows.activity = original
        end)
    end)

    describe("_try_record_edit_range", function()
        --- @type string
        local path

        before_each(function()
            path = vim.fn.tempname()
            vim.fn.writefile({ "a", "foo", "z" }, path)
        end)

        after_each(function()
            vim.fs.rm(path)
        end)

        --- @return agentic.SessionManager
        --- @return table[] recorded
        local function make_session()
            --- @type table[]
            local recorded = {}
            --- @type agentic.SessionManager
            local session = {
                message_writer = {
                    tool_call_blocks = {
                        ["tc-1"] = {
                            kind = "edit",
                            status = "pending",
                            argument = path,
                            diff = { old = { "foo" }, new = { "foo", "bar" } },
                        },
                    },
                },
                permission_manager = {
                    has_edit_range = function()
                        return false
                    end,
                    record_pending_edit = function(_self, id, _, start_line)
                        table.insert(recorded, { id, start_line })
                    end,
                },
                _view_for = SessionManager._view_for,
                _try_record_edit_range = SessionManager._try_record_edit_range,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            return session, recorded
        end

        it("records a live pending edit", function()
            local session, recorded = make_session()

            session:_try_record_edit_range("tc-1")

            assert.same({ { "tc-1", 2 } }, recorded)
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
            return with_subagents({
                session_id = "s-1",
                id = 1,
                is_generating = false,
                _is_first_message = false,
                destroyed = false,
                _transient_attempt = 0,
                agent = {
                    state = "ready",
                    provider_config = { name = "Test" },
                    send_prompt = function(_self, _sid, _prompt, cb)
                        cb(nil, send_err)
                    end,
                    drain_side_records = function()
                        return {}
                    end,
                },
                message_writer = {
                    write_message = noop,
                    write_user_prompt = noop,
                    write_error_message = function()
                        return nil, nil
                    end,
                    finalize_turn = noop,
                    set_turn_usage = noop,
                    any_following = empty,
                    tool_call_blocks = {},
                },
                _end_open_tool_calls = noop,
                _finalize_turn = SessionManager._finalize_turn,
                _drain_side_records = SessionManager._drain_side_records,
                _held_tool_call_updates = {},
                status_indicator = { start = noop, stop = noop },
                chat_history = {
                    session_id = "s-1",
                    add_message = noop,
                    set_title = ChatHistory.set_title,
                    has_prompt = ChatHistory.has_prompt,
                    save = function(this)
                        this.dirty = false
                    end,
                    messages = { { type = "user", text = "go" } },
                    title = "",
                    dirty = false,
                },
                widget = {
                    buf_nrs = { agent = 0 },
                    get_chat_width = function()
                        return 80
                    end,
                    set_idle = noop,
                    set_waiting = noop,
                    set_running = noop,
                    set_chat_title = noop,
                    input_dispatch = {
                        next_queued_block = function()
                            return nil
                        end,
                        consume_queued_block = noop,
                    },
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
                _submit_hold_reason = SessionManager._submit_hold_reason,
                _handle_input_submit_inner = SessionManager._handle_input_submit_inner,
                _send_user_prompt = SessionManager._send_user_prompt,
                _dispatch_turn = SessionManager._dispatch_turn,
                _set_generating = SessionManager._set_generating,
                _notify_attention = SessionManager._notify_attention,
                file_activity = { serialize = noop },
                config_options = { current_model_id = noop },
                _sync_history_context = SessionManager._sync_history_context,
                _persist_history = SessionManager._persist_history,
                _history_changed = SessionManager._history_changed,
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
                _drain_queue = SessionManager._drain_queue,
                _dispatch_deferred_prompts = SessionManager._dispatch_deferred_prompts,
                _submit_defer_reason = SessionManager._submit_defer_reason,
                _prompt_pending = 0,
            } --[[@as agentic.SessionManager]])
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

    describe("send_prompt error dispatch", function()
        local MessageWriter = require("agentic.ui.message_writer")
        local Recovery = require("agentic.session_recovery")
        --- @type TestStub
        local login_stub
        --- @type TestStub
        local respawn_stub
        --- @type TestStub
        local auto_continue_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local restore_stub

        before_each(function()
            restore_stub = spy.stub(Recovery, "restore_refused_prompt")
            login_stub = spy.stub(Recovery, "offer_login")
            respawn_stub = spy.stub(Recovery, "respawn_preserving_history")
            auto_continue_stub = spy.stub(Recovery, "offer_auto_continue")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            restore_stub:revert()
            login_stub:revert()
            respawn_stub:revert()
            auto_continue_stub:revert()
            schedule_stub:revert()
        end)

        --- Minimal session whose send_prompt errors and whose
        --- write_error_message reports the given class. `send_err` overrides the
        --- error object the provider callback reports; `sink` collects the
        --- writes and prompts the turn tail produces.
        --- @param error_type string|nil
        --- @param send_err table|nil
        --- @param sink table|nil
        --- @return agentic.SessionManager
        local function make_session(error_type, send_err, sink)
            local noop = function() end
            local empty = function()
                return true
            end
            sink = sink or {}
            sink.drains = sink.drains or 0
            sink.errors = sink.errors or {}
            sink.actions = sink.actions or {}
            sink.prompts = sink.prompts or {}
            sink.synthetic = sink.synthetic or {}
            sink.headings = sink.headings or {}
            sink.history = sink.history or {}
            sink.history_updates = sink.history_updates or {}
            sink.stamped = sink.stamped or {}

            --- Records the stamp under `key` and makes the status stick, so a
            --- second sweep over the same writer finds nothing left.
            --- @param key string Which writer the stamp went to
            --- @return fun(this: table, update: table)
            local function record_stamp(key)
                sink.stamped[key] = {}
                return function(this, update)
                    table.insert(sink.stamped[key], update)
                    this.tool_call_blocks[update.tool_call_id].status =
                        update.status
                end
            end

            local session = with_subagents({
                session_id = "s-1",
                id = 1,
                is_generating = false,
                _is_first_message = false,
                destroyed = false,
                _retry_attempt = 0,
                _transient_attempt = 0,
                _session_epoch = 0,
                agent = {
                    state = "ready",
                    provider_config = { name = "Test" },
                    send_prompt = function(_self, _sid, prompt, cb)
                        sink.saves_at_send = sink.saves_at_send
                            or (sink.saves or 0)
                        table.insert(sink.prompts, prompt)
                        cb(nil, send_err or { message = "boom" })
                    end,
                    drain_side_records = function()
                        return {}
                    end,
                },
                message_writer = {
                    write_message = noop,
                    write_user_prompt = function(_self, text)
                        table.insert(sink.headings, text)
                    end,
                    write_error_message = function(_self, err)
                        table.insert(sink.errors, err)
                        return error_type, nil
                    end,
                    write_error_action = function(_self, text)
                        table.insert(sink.actions, text)
                    end,
                    finalize_turn = noop,
                    set_turn_usage = noop,
                    any_following = empty,
                    tool_call_blocks = {},
                    nonfinal_tool_call_ids = MessageWriter.nonfinal_tool_call_ids,
                    stamp_open_calls = MessageWriter.stamp_open_calls,
                    update_tool_call_block = record_stamp("main"),
                },
                _end_open_tool_calls = SessionManager._end_open_tool_calls,
                _finalize_turn = SessionManager._finalize_turn,
                _drain_side_records = SessionManager._drain_side_records,
                _held_tool_call_updates = {},
                status_indicator = { start = noop, stop = noop },
                chat_history = {
                    session_id = "s-1",
                    add_message = function(_self, msg)
                        table.insert(sink.history, msg)
                    end,
                    update_tool_call = function(_self, id, update)
                        table.insert(sink.history_updates, { id, update })
                    end,
                    update_tool_calls = ChatHistory.update_tool_calls,
                    set_title = ChatHistory.set_title,
                    has_prompt = ChatHistory.has_prompt,
                    save = function(this)
                        sink.saves = (sink.saves or 0) + 1
                        sink.updates_at_save = #sink.history_updates
                        this.dirty = false
                    end,
                    messages = { { type = "user", text = "go" } },
                    title = "",
                    dirty = false,
                },
                widget = {
                    buf_nrs = { agent = 0 },
                    get_chat_width = function()
                        return 80
                    end,
                    set_idle = noop,
                    set_waiting = noop,
                    set_running = noop,
                    set_chat_title = noop,
                    input_dispatch = {
                        next_queued_block = function()
                            sink.drains = (sink.drains or 0) + 1
                            return nil
                        end,
                        consume_queued_block = noop,
                    },
                },
                permission_manager = { current_request = nil, queue = {} },
                todo_list = { close_if_all_completed = noop },
                file_list = { is_empty = empty },
                code_selection = { is_empty = empty },
                diagnostics_list = { is_empty = empty },
                _ring_bell = noop,
                _handle_input_submit = SessionManager._handle_input_submit,
                _submit_hold_reason = SessionManager._submit_hold_reason,
                _handle_input_submit_inner = SessionManager._handle_input_submit_inner,
                _send_user_prompt = SessionManager._send_user_prompt,
                _dispatch_turn = SessionManager._dispatch_turn,
                _set_generating = SessionManager._set_generating,
                _send_synthetic_prompt = function(this, text)
                    table.insert(sink.synthetic, text)
                    SessionManager._send_synthetic_prompt(this, text)
                end,
                _notify_attention = SessionManager._notify_attention,
                file_activity = { serialize = noop },
                config_options = { current_model_id = noop },
                _sync_history_context = SessionManager._sync_history_context,
                _persist_history = SessionManager._persist_history,
                _history_changed = SessionManager._history_changed,
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
                _drain_queue = SessionManager._drain_queue,
                _dispatch_deferred_prompts = SessionManager._dispatch_deferred_prompts,
                _submit_defer_reason = SessionManager._submit_defer_reason,
                _prompt_pending = 0,
            } --[[@as agentic.SessionManager]])
            -- A running subagent.
            session._subagents._agents.c1 = {
                open = true,
                record_read = true,
                transcript = {
                    view = {
                        writer = {
                            tool_call_blocks = {},
                            nonfinal_tool_call_ids = MessageWriter.nonfinal_tool_call_ids,
                            stamp_open_calls = MessageWriter.stamp_open_calls,
                            update_tool_call_block = record_stamp("subagent"),
                        },
                    },
                    set_modified = noop,
                },
            }
            return session
        end

        describe("in-flight gate accounting", function()
            it("releases the gate when the turn's callback lands", function()
                local session = make_session(nil, nil, {})
                session.agent.send_prompt = function(_self, _sid, _p, cb)
                    assert.equal(1, session._prompt_pending)
                    cb({ stopReason = "end_turn" }, nil)
                end

                session:_handle_input_submit("hello")

                assert.equal(0, session._prompt_pending)
            end)

            -- A cancelled prompt's callback outlives /new or a resume.
            -- Decrementing then would report the session idle while the turn
            -- that replaced it is still running.
            it("ignores a callback from a superseded session", function()
                local session = make_session(nil, nil, {})
                local resolve
                session.agent.send_prompt = function(_self, _sid, _p, cb)
                    resolve = cb
                end

                session:_handle_input_submit("hello")
                -- /new or a resume between send and callback.
                session._session_epoch = session._session_epoch + 1
                session._prompt_pending = 1 -- the replacement turn
                resolve({ stopReason = "cancelled" }, nil)

                assert.equal(1, session._prompt_pending)
            end)

            -- A subagent's tool calls resolve their writer through this table
            -- for as long as it runs, so a turn dispatched over it leaves it.
            it("leaves the running subagents' tool state alone", function()
                local session = make_session(nil, nil, {})
                session.agent.send_prompt = function() end

                session:_handle_input_submit("first")
                session._subagents._tool_call_owner["tc-1"] = "c1"
                session:_handle_input_submit("second")

                assert.equal("c1", session._subagents._tool_call_owner["tc-1"])
                assert.is_true(session._subagents._agents.c1.open)
            end)

            it(
                "keeps a turn outstanding when a submit lands mid-turn",
                function()
                    local sink = {}
                    local session = make_session(nil, nil, sink)
                    session.agent.send_prompt = function(_self, _sid, prompt)
                        table.insert(sink.prompts, prompt)
                    end

                    assert.is_true(session:_handle_input_submit("first"))
                    assert.is_true(session:_handle_input_submit("second"))

                    assert.equal(2, #sink.prompts)
                    assert.equal(2, session._prompt_pending)
                end
            )

            -- A turn ending with the mid-turn submit's turn still outstanding
            -- owes the reader its own boundary — the footer, the separator and
            -- the per-turn writer flags, which corrupt the next turn if they
            -- carry — but none of the signals that say the session went idle.
            it("ends its own turn without ending the session's", function()
                local sink = {}
                local session = make_session(nil, nil, sink)
                local resolve
                session.agent.send_prompt = function(_self, _sid, _p, cb)
                    resolve = cb
                end
                local finalized = 0
                session.message_writer.finalize_turn = function()
                    finalized = finalized + 1
                end
                local stopped = 0
                session.status_indicator.stop = function()
                    stopped = stopped + 1
                end
                local consumed = 0
                session.widget.input_dispatch.next_queued_block = function()
                    return { text = "queued", sr = 0, er = 0 }
                end
                session.widget.input_dispatch.consume_queued_block = function()
                    consumed = consumed + 1
                end

                session:_handle_input_submit("hello")
                session._prompt_pending = 2 -- the mid-turn submit's own turn
                session.is_generating = true
                resolve({ stopReason = "end_turn" }, nil)

                assert.equal(1, finalized)
                assert.is_true(session.is_generating)
                assert.equal(0, stopped)
                -- The queue still advances one block per turn, which is the one
                -- thing the in-flight reason is left to hold.
                assert.equal(0, consumed)
            end)
        end)

        describe("unfinished turn's tool call sweep", function()
            --- Run one turn that resolves with `response`, over a session
            --- holding one non-final and one completed call in the chat and in
            --- a running subagent's transcript.
            --- @param response table
            --- @return table sink
            local function turn_over_pending_calls(response)
                local sink = {}
                local session = make_session(nil, nil, sink)
                session.message_writer.tool_call_blocks = {
                    ["main-pending"] = { status = "pending" },
                    ["main-done"] = { status = "completed" },
                }
                session._subagents._agents.c1.transcript.view.writer.tool_call_blocks =
                    {
                        ["sub-running"] = { status = "in_progress" },
                        ["sub-done"] = { status = "completed" },
                    }
                session.agent.send_prompt = function(_self, _sid, _p, cb)
                    cb(response, nil)
                end
                session:_handle_input_submit("hello")
                return sink
            end

            -- A running subagent can outlive the turn, so its own end stamps
            -- its calls.
            for reason, word in pairs({
                cancelled = "interrupted",
                max_tokens = "max_tokens",
                refusal = "refusal",
            }) do
                it(
                    "stamps the chat's non-final calls, not a subagent's, at "
                        .. reason,
                    function()
                        local sink =
                            turn_over_pending_calls({ stopReason = reason })

                        assert.same({
                            {
                                tool_call_id = "main-pending",
                                status = "failed",
                                ended_as = word,
                            },
                        }, sink.stamped.main)
                        assert.same({}, sink.stamped.subagent)
                    end
                )
            end

            it("ends the chat's non-final calls failed at an error", function()
                local sink = {}
                local session =
                    make_session(nil, { code = -32603, message = "boom" }, sink)
                session.message_writer.tool_call_blocks = {
                    ["main-pending"] = { status = "pending" },
                }
                session:_handle_input_submit("hello")

                assert.same({
                    {
                        tool_call_id = "main-pending",
                        status = "failed",
                        ended_as = "failed",
                    },
                }, sink.stamped.main)
            end)

            it("persists the chat's stamps", function()
                local sink =
                    turn_over_pending_calls({ stopReason = "cancelled" })

                assert.same({
                    {
                        "main-pending",
                        {
                            type = "tool_call",
                            tool_call_id = "main-pending",
                            status = "failed",
                            ended_as = "interrupted",
                        },
                    },
                }, sink.history_updates)
                -- The sweep has to precede the save, or the footer comes back
                -- from a resume still reading `pending`.
                assert.equal(1, sink.updates_at_save)
            end)

            it("leaves a normally-ended turn's calls alone", function()
                local sink =
                    turn_over_pending_calls({ stopReason = "end_turn" })

                assert.same({}, sink.stamped.main)
                assert.same({}, sink.stamped.subagent)
                assert.same({}, sink.history_updates)
            end)
        end)

        describe("drain trigger", function()
            --- Run one turn that resolves with `response`, no error.
            --- @param response table|nil
            --- @return integer drains
            local function drains_after(response)
                local sink = {}
                local session = make_session(nil, nil, sink)
                session.agent.send_prompt = function(_self, _sid, prompt, cb)
                    table.insert(sink.prompts, prompt)
                    cb(response, nil)
                end
                session:_handle_input_submit("hello")
                return sink.drains
            end

            it("drains on a normal end_turn", function()
                assert.equal(1, drains_after({ stopReason = "end_turn" }))
                assert.equal(1, drains_after({}))
            end)

            -- <C-c>. The user stopping a turn that went sideways is asking a
            -- question, not releasing the next task.
            it("does not drain a cancelled turn", function()
                assert.equal(0, drains_after({ stopReason = "cancelled" }))
            end)

            it("does not drain a turn that ended early", function()
                assert.equal(0, drains_after({ stopReason = "refusal" }))
                assert.equal(0, drains_after({ stopReason = "max_tokens" }))
                assert.equal(
                    0,
                    drains_after({ stopReason = "max_turn_requests" })
                )
            end)
        end)

        describe("refusal", function()
            --- A session whose turns end with `response` and `err`.
            --- @param response table|nil
            --- @param err table|nil
            --- @return agentic.SessionManager session
            local function refusing_session(response, err)
                local session = make_session(nil, nil, {})
                session.agent.send_prompt = function(_self, _sid, _p, cb)
                    cb(response, err)
                end
                session._relay = SessionManager._relay
                return session
            end

            --- A context panel that holds `items`.
            --- @param items table[]
            --- @return table
            local function panel(items)
                return {
                    is_empty = function()
                        return false
                    end,
                    take = function()
                        return items
                    end,
                }
            end

            --- A session whose prompt ends refused with every context panel
            --- holding one item.
            --- @return agentic.SessionManager session
            --- @return table context The items, by `PanelContext` field
            local function session_with_context()
                local session = refusing_session({ stopReason = "refusal" })
                local context = {
                    selections = {
                        {
                            lines = { "x" },
                            start_line = 1,
                            end_line = 1,
                            file_path = "/a.lua",
                            file_type = "lua",
                        },
                    },
                    files = { "/b.lua" },
                    diagnostics = { { message = "d" } },
                }
                session.code_selection = panel(context.selections)
                session.file_list = panel(context.files)
                session.diagnostics_list = panel(context.diagnostics)
                session.widget.home_win = function() end
                return session, context
            end

            local DiagnosticsContext = require("agentic.ui.diagnostics_context")
            --- @type TestStub
            local format_stub

            before_each(function()
                format_stub = spy.stub(DiagnosticsContext, "format_diagnostics")
                format_stub:returns({ prompt_entries = {}, summary_lines = {} })
            end)

            after_each(function()
                format_stub:revert()
            end)

            it("returns the prompt with the context it took", function()
                local session, context = session_with_context()

                session:_handle_input_submit("hello")

                assert.spy(restore_stub).was.called(1)
                local call = restore_stub.calls[1]
                assert.equal(session, call[1])
                assert.equal("hello", call[2])
                assert.same(context, call[3])
                assert.is_nil(call[4])
            end)

            it("returns a command with no context", function()
                local session = session_with_context()

                session:_handle_input_submit("/compact")

                assert.equal("/compact", restore_stub.calls[1][2])
                assert.same(
                    { selections = {}, files = {}, diagnostics = {} },
                    restore_stub.calls[1][3]
                )
            end)

            it("returns the prompt with a later turn outstanding", function()
                local session = refusing_session()
                --- @type function
                local resolve
                session.agent.send_prompt = function(_self, _sid, _p, cb)
                    resolve = cb
                end

                session:_handle_input_submit("hello")
                session._prompt_pending = 2
                resolve({ stopReason = "refusal" }, nil)

                assert.spy(restore_stub).was.called(1)
            end)

            it("returns nothing to a destroyed or replaced session", function()
                for _, supersede in ipairs({
                    function(session)
                        session.destroyed = true
                    end,
                    function(session)
                        session._session_epoch = 1
                    end,
                }) do
                    local session = refusing_session()
                    --- @type function
                    local resolve
                    session.agent.send_prompt = function(_self, _sid, _p, cb)
                        resolve = cb
                    end

                    session:_handle_input_submit("hello")
                    supersede(session)
                    resolve({ stopReason = "refusal" }, nil)
                end

                assert.spy(restore_stub).was.called(0)
            end)

            it("leaves other turn endings alone", function()
                refusing_session({ stopReason = "end_turn" }):_handle_input_submit(
                    "a"
                )
                refusing_session({ stopReason = "max_tokens" }):_handle_input_submit(
                    "b"
                )
                refusing_session(nil, { message = "boom" }):_handle_input_submit(
                    "c"
                )

                assert.spy(restore_stub).was.called(0)
            end)

            it("returns nothing for a synthetic prompt", function()
                refusing_session({ stopReason = "refusal" }):_send_synthetic_prompt(
                    "continue"
                )

                assert.spy(restore_stub).was.called(0)
            end)

            describe("of a relay", function()
                it("restores nothing without on_refusal", function()
                    local session = refusing_session({ stopReason = "refusal" })

                    assert.is_nil(session:_relay("hi", { force = false }, nil))

                    assert.spy(restore_stub).was.called(0)
                end)

                it("runs on_refusal", function()
                    local session = refusing_session({ stopReason = "refusal" })
                    local on_refusal = spy.new(function() end)

                    session:_relay("hi", { force = false }, on_refusal)

                    assert.spy(on_refusal).was.called(1)
                end)

                it("returns the notice of a held relay", function()
                    local session = refusing_session({ stopReason = "refusal" })
                    session._loading = true

                    assert.equal(
                        "Message held — the session is still loading.",
                        session:_relay("hi", { force = false }, nil)
                    )
                end)
            end)
        end)

        it("billing_error offers no login, respawn or auto-continue", function()
            local session = make_session("billing_error")
            session:_handle_input_submit("hello")
            assert.spy(login_stub).was.called(0)
            assert.spy(respawn_stub).was.called(0)
            assert.spy(auto_continue_stub).was.called(0)
        end)

        it("auth required offers login", function()
            local session = make_session(nil, {
                code = ACPClient.ERROR_CODES.AUTH_REQUIRED,
                message = "Authentication required",
            })
            session:_handle_input_submit("hello")
            assert.spy(login_stub).was.called(1)
            assert.spy(respawn_stub).was.called(0)
        end)

        -- The code is the signal, not the classification of the message.
        it(
            "a transport error classed as authentication offers no login",
            function()
                local session = make_session("authentication_error", {
                    code = ACPClient.ERROR_CODES.TRANSPORT_ERROR,
                    message = "disconnected",
                })
                session:_handle_input_submit("hello")
                assert.spy(login_stub).was.called(0)
            end
        )

        it("auth required with a usage-limit body offers login", function()
            local session = make_session("usage_limit", {
                code = ACPClient.ERROR_CODES.AUTH_REQUIRED,
                message = "Authentication required",
            })
            session:_handle_input_submit("hello")
            assert.spy(login_stub).was.called(1)
            assert.spy(respawn_stub).was.called(0)
        end)

        -- A turn that worked is the only evidence the refreshed credentials
        -- took, and so the only thing that re-arms the cheap recovery.
        it("clears a spent live re-auth retry on success", function()
            local session = make_session(nil, nil, {})
            session._reauth_live_retry = true
            session.agent.send_prompt = function(_self, _sid, _p, cb)
                cb({ stopReason = "end_turn" }, nil)
            end

            session:_handle_input_submit("hello")

            assert.is_false(session._reauth_live_retry)
        end)

        describe("persisting the conversation", function()
            local TRANSIENT =
                { message = "boom", data = { errorKind = "server_error" } }
            local original_enabled

            before_each(function()
                original_enabled = Config.auto_retry_on_transient_error
                Config.auto_retry_on_transient_error = true
            end)

            after_each(function()
                Config.auto_retry_on_transient_error = original_enabled
            end)

            -- The user prompt is in chat_history from submit, so a first turn
            -- that fails would otherwise leave no file to recover it from.
            it("saves the history a failed turn holds", function()
                local sink = {}
                local session = make_session(nil, { message = "boom" }, sink)

                session:_handle_input_submit("hello")

                -- Saves made by the turn itself, not by the submit's
                -- idle-session save of the user prompt.
                assert.equal(1, sink.saves - sink.saves_at_send)
            end)

            it("saves once when the failed turn is resent", function()
                local sink = {}
                local session = make_session(nil, TRANSIENT, sink)
                local sent = 0
                session.agent.send_prompt = function(_self, _sid, prompt, cb)
                    sink.saves_at_send = sink.saves_at_send or (sink.saves or 0)
                    sent = sent + 1
                    table.insert(sink.prompts, prompt)
                    cb(
                        { stopReason = "end_turn" },
                        sent == 1 and TRANSIENT or nil
                    )
                end

                session:_handle_input_submit("hello")

                assert.equal(2, #sink.prompts)
                -- The resend's synthetic row, then the turn end.
                assert.equal(2, sink.saves - sink.saves_at_send)
            end)
        end)

        describe("transient auto-retry", function()
            local TRANSIENT =
                { message = "boom", data = { errorKind = "server_error" } }
            --- @type TestStub
            local bell_stub
            local original_enabled
            local original_hooks
            local completions

            before_each(function()
                original_enabled = Config.auto_retry_on_transient_error
                original_hooks = Config.hooks
                Config.auto_retry_on_transient_error = true
                completions = {}
                Config.hooks = {
                    on_response_complete = function(data)
                        table.insert(completions, data)
                    end,
                }
                bell_stub = spy.stub(SessionManager, "_ring_bell")
            end)

            after_each(function()
                Config.auto_retry_on_transient_error = original_enabled
                Config.hooks = original_hooks
                bell_stub:revert()
            end)

            --- Session that fails `n_failures` turns with a transient error
            --- and succeeds after that.
            --- @param n_failures number
            --- @return agentic.SessionManager session
            --- @return table sink
            local function make_transient_session(n_failures)
                local sink = {}
                local session = make_session(nil, TRANSIENT, sink)
                local sent = 0
                session.agent.send_prompt = function(_self, _sid, prompt, cb)
                    sent = sent + 1
                    table.insert(sink.prompts, prompt)
                    cb(
                        { stopReason = "end_turn" },
                        sent <= n_failures and TRANSIENT or nil
                    )
                end
                return session, sink
            end

            it("retries silently and leaves no trace on recovery", function()
                local session, sink = make_transient_session(2)
                session:_handle_input_submit("hello")

                assert.equal(0, #sink.errors)
                assert.equal(0, #sink.actions)
                assert.same({ "continue", "continue" }, sink.synthetic)
                -- Only the user's own prompt is attributed to them: one
                -- heading, one typed history entry, one bell, one drain, one
                -- hook.
                assert.same({ "hello" }, sink.headings)
                assert.same(
                    { false, true, true },
                    vim.tbl_map(function(msg)
                        return msg.synthetic == true
                    end, sink.history)
                )
                assert.spy(bell_stub).was.called(1)
                assert.equal(1, sink.drains)
                assert.equal(1, #completions)
                assert.is_true(completions[1].success)
            end)

            it("gives up after 3 attempts and reports the count", function()
                local session, sink = make_transient_session(math.huge)
                session:_handle_input_submit("hello")

                assert.equal(4, #sink.prompts)
                assert.equal(3, #sink.synthetic)
                assert.equal(1, #sink.errors)
                assert.same(
                    { "Auto-retry gave up (3 attempts)." },
                    sink.actions
                )
                assert.equal(0, session._transient_attempt)
                assert.same({ "hello" }, sink.headings)
                assert.spy(bell_stub).was.called(1)
                -- An abnormal Stop parks the queue: launching a follow-up onto
                -- a turn that never finished its work is wrong, and the text
                -- stays visible in the input buffer meanwhile.
                assert.equal(0, sink.drains)
                assert.equal(1, #completions)
                assert.is_false(completions[1].success)
            end)

            it("does not retry into a session replaced mid-flight", function()
                local sink = {}
                local session = make_session(nil, TRANSIENT, sink)
                session.agent.send_prompt = function(_self, _sid, prompt, cb)
                    table.insert(sink.prompts, prompt)
                    -- /new, a resume or a provider switch between send and
                    -- callback: the pending callback outlives cancel_session.
                    session.session_id = "s-2"
                    cb(nil, TRANSIENT)
                end
                session:_handle_input_submit("hello")

                assert.equal(0, #sink.synthetic)
                assert.equal(1, #sink.errors)
                assert.equal(0, sink.drains)
            end)

            it("does not retry when the agent is not ready", function()
                local sink = {}
                local session = make_session(nil, TRANSIENT, sink)
                session.agent.send_prompt = function(_self, _sid, prompt, cb)
                    table.insert(sink.prompts, prompt)
                    session.agent.state = "connecting"
                    cb(nil, TRANSIENT)
                end
                session:_handle_input_submit("hello")

                assert.equal(0, #sink.synthetic)
                assert.equal(1, #sink.errors)
            end)

            -- The user submitted mid-turn and has taken over. A silent resend
            -- would land behind their prompt and read as a follow-up to it.
            it("does not retry under a turn the user submitted", function()
                local sink = {}
                local session = make_session(nil, TRANSIENT, sink)
                session.agent.send_prompt = function(_self, _sid, prompt, cb)
                    table.insert(sink.prompts, prompt)
                    session._prompt_pending = 2 -- the mid-turn submit's turn
                    cb(nil, TRANSIENT)
                end
                session:_handle_input_submit("hello")

                assert.equal(0, #sink.synthetic)
                assert.equal(1, #sink.errors)
            end)

            it("does not retry an error without server_error kind", function()
                local sink = {}
                local session = make_session(nil, { message = "boom" }, sink)
                session:_handle_input_submit("hello")

                assert.equal(0, #sink.synthetic)
                assert.equal(1, #sink.errors)
                assert.equal(0, #sink.actions)
            end)

            it("does not retry when disabled", function()
                Config.auto_retry_on_transient_error = false
                local sink = {}
                local session = make_session(nil, TRANSIENT, sink)
                session:_handle_input_submit("hello")

                assert.equal(0, #sink.synthetic)
                assert.equal(1, #sink.errors)
            end)

            it(
                "reports retries when the chain ends in another class",
                function()
                    local sink = {}
                    local session = make_session(nil, TRANSIENT, sink)
                    local sent = 0
                    session.agent.send_prompt = function(
                        _self,
                        _sid,
                        prompt,
                        cb
                    )
                        sent = sent + 1
                        table.insert(sink.prompts, prompt)
                        cb(
                            nil,
                            sent <= 2 and TRANSIENT or { message = "different" }
                        )
                    end
                    session:_handle_input_submit("hello")

                    assert.equal(2, #sink.synthetic)
                    assert.equal(1, #sink.errors)
                    assert.same(
                        { "Auto-retry gave up (2 attempts)." },
                        sink.actions
                    )
                    assert.equal(0, session._transient_attempt)
                end
            )
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
                    id = 1,
                    tool_call_id = "tc-1",
                })
            end)

            assert.is_not_nil(hook_data)
            assert.equal("s-1", hook_data.session_id)
            assert.equal("tc-1", hook_data.tool_call_id)
        end)
    end)

    describe("_on_request_permission attention gating", function()
        --- @type TestStub
        local bell_stub
        --- @type TestStub
        local schedule_stub
        local original_notifications
        local original_hooks

        before_each(function()
            original_notifications = Config.notifications
            original_hooks = Config.hooks
            Config.notifications = { bell = true }
            bell_stub = spy.stub(SessionManager, "_ring_bell")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            Config.notifications = original_notifications
            Config.hooks = original_hooks
            bell_stub:revert()
            schedule_stub:revert()
        end)

        --- @param prompted boolean value add_request should report
        local function make_session(prompted)
            local noop = function() end
            local hook_calls = {}
            Config.hooks = {
                on_permission_request = function(data)
                    table.insert(hook_calls, data)
                end,
            }
            local session = {
                session_id = "s-1",
                id = 1,
                destroyed = false,
                status_indicator = { start = noop, stop = noop },
                message_writer = { tool_call_blocks = {} },
                _view_for = SessionManager._view_for,
                -- chat not current => unfocused => bell would ring if notified
                widget = {
                    buf_nrs = { agent = -1 },
                },
                permission_manager = {
                    add_request = function()
                        return prompted
                    end,
                    permission_float = {
                        is_visible_in_current_tab = function()
                            return true
                        end,
                    },
                },
                _notify_attention = SessionManager._notify_attention,
                _on_request_permission = SessionManager._on_request_permission,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            return session, hook_calls
        end

        local request = {
            toolCall = { toolCallId = "tc-1" },
            options = {},
        }

        it("stays silent when add_request auto-approves", function()
            local session, hook_calls = make_session(false)
            session:_on_request_permission(request, function() end)
            assert.spy(bell_stub).was.called(0)
            assert.equal(0, #hook_calls)
        end)

        it("rings bell and fires hook on an interactive prompt", function()
            local session, hook_calls = make_session(true)
            session:_on_request_permission(request, function() end)
            assert.spy(bell_stub).was.called(1)
            assert.equal(1, #hook_calls)
            assert.equal("tc-1", hook_calls[1].tool_call_id)
        end)
    end)

    describe("local command interception", function()
        --- @type agentic.SessionManager
        local session
        --- @type TestSpy
        local dispatch_spy
        --- @type TestSpy
        local new_session_spy
        --- @type TestSpy
        local grant_spy
        --- @type TestSpy
        local delete_spy
        --- @type TestSpy
        local rename_spy

        before_each(function()
            local noop = function() end
            local empty = function()
                return true
            end

            dispatch_spy = spy.new(noop)
            grant_spy = spy.new(noop)
            delete_spy = spy.new(noop)
            rename_spy = spy.new(noop)
            new_session_spy = spy.new(function(_self, opts)
                if opts and opts.on_created then
                    opts.on_created()
                end
            end)

            session = {
                session_id = "s-1",
                id = 1,
                _is_first_message = false,
                _prompt_pending = 0,
                agent = { state = "ready", provider_config = { name = "Test" } },
                message_writer = {
                    write_user_prompt = noop,
                    write_error_action = noop,
                },
                chat_history = { title = "existing", add_message = noop },
                _history_changed = noop,
                widget = {
                    buf_nrs = { input = 0 },
                    set_idle = noop,
                    set_chat_title = noop,
                    input_dispatch = {
                        cancel_queue = noop,
                        next_queued_block = function()
                            return nil
                        end,
                        queued_block_count = function()
                            return 0
                        end,
                    },
                },
                todo_list = { close_if_all_completed = noop },
                code_selection = { is_empty = empty },
                file_list = { is_empty = empty },
                diagnostics_list = { is_empty = empty },
                new_session = new_session_spy,
                _rename_session = rename_spy,
                _grant_command = { run = grant_spy },
                _delete_session = delete_spy,
                _dispatch_turn = dispatch_spy,
                _submit_defer_reason = SessionManager._submit_defer_reason,
                _run_local_command = SessionManager._run_local_command,
                _drain_queue = SessionManager._drain_queue,
                _truncate_queue = SessionManager._truncate_queue,
                _handle_input_submit = SessionManager._handle_input_submit,
                _submit_hold_reason = SessionManager._submit_hold_reason,
                _handle_input_submit_inner = SessionManager._handle_input_submit_inner,
                _send_user_prompt = SessionManager._send_user_prompt,
            } --[[@as agentic.SessionManager]]
        end)

        --- Submit each text and return how many reached the provider untouched.
        --- @param texts string[]
        --- @return integer
        local function count_dispatched_as_prose(texts)
            for _, text in ipairs(texts) do
                session:_handle_input_submit(text)
            end
            assert.equal(0, new_session_spy.call_count)
            assert.equal(0, grant_spy.call_count)
            assert.equal(0, delete_spy.call_count)
            return dispatch_spy.call_count
        end

        it(
            "sends a word merely starting with a command name as prose",
            function()
                local texts = {
                    "/newsflash: build broken",
                    "/granted, it works",
                    "/clearance to land",
                    "/contextual clue",
                    "/renamed the file",
                    "/deleted the file",
                }
                assert.equal(#texts, count_dispatched_as_prose(texts))
            end
        )

        it("sends a command name followed by punctuation as prose", function()
            -- A word boundary is whitespace or end-of-string, not any non-word
            -- character: `/grant/etc` compiling as a path scope would silently
            -- widen edit permissions.
            local texts = {
                "/new: build broken",
                "/new/data/f.csv please read this",
                "/new-parser is failing",
                "/grant: what does this mean?",
                "/grant/etc",
            }
            assert.equal(#texts, count_dispatched_as_prose(texts))
        end)

        it("sends a command spanning two lines as prose", function()
            -- A title argument stops at the line the command is on, so the
            -- second line is never swallowed as part of it.
            assert.equal(1, count_dispatched_as_prose({ "/new\nStart on X" }))
        end)

        it("still intercepts /new, with or without trailing space", function()
            session:_handle_input_submit("/new")
            session:_handle_input_submit("/new ")
            assert.equal(2, new_session_spy.call_count)
            assert.equal(0, rename_spy.call_count)
            assert.equal(0, dispatch_spy.call_count)
        end)

        it("names the fresh session after a /new or /clear argument", function()
            session:_handle_input_submit("/new fresh start")
            session:_handle_input_submit("/clear  my work  ")
            assert.equal(2, new_session_spy.call_count)
            assert.equal(0, dispatch_spy.call_count)
            assert.equal("fresh start", rename_spy.calls[1][2])
            assert.equal("my work", rename_spy.calls[2][2])
        end)

        it("still intercepts /grant, bare and with a scope argument", function()
            session:_handle_input_submit("/grant")
            session:_handle_input_submit("/grant root")
            assert.equal(2, grant_spy.call_count)
            assert.equal("", grant_spy.calls[1][2])
            assert.equal("root", grant_spy.calls[2][2])
            assert.equal(0, dispatch_spy.call_count)
        end)

        it("dispatches /login to the login flow", function()
            local Recovery = require("agentic.session_recovery")
            local login_stub = spy.stub(Recovery, "login")
            MiniTest.finally(function()
                login_stub:revert()
            end)

            session:_handle_input_submit("/login console-login")

            assert.equal("console-login", login_stub.calls[1][2])
            assert.equal("function", type(login_stub.calls[1][3]))
            assert.equal(0, dispatch_spy.call_count)
        end)

        -- Local commands need no provider round-trip, so the gate must never
        -- park them: they are how a wedged session gets recovered.
        it("runs local commands mid-turn and before the session", function()
            session._prompt_pending = 1
            assert.is_true(session:_handle_input_submit("/new"))

            session._prompt_pending = 0
            session.session_id = nil
            assert.is_true(session:_handle_input_submit("/delete"))

            session._usage_reset_epoch = os.time() + 600
            assert.is_true(session:_handle_input_submit("/grant root"))

            assert.equal(1, new_session_spy.call_count)
            assert.equal(1, delete_spy.call_count)
            assert.equal(1, grant_spy.call_count)
            assert.equal(0, dispatch_spy.call_count)
        end)

        it("sends an unadvertised command without a warning", function()
            local warning_spy = spy.new(function() end)
            session.message_writer.write_error_action = warning_spy --[[@as function]]
            session._available_commands =
                { { name = "review", description = "Review" } }

            session:_handle_input_submit("/implement plan.md")

            assert.equal(1, dispatch_spy.call_count)
            assert.spy(warning_spy).was.called(0)
        end)
    end)

    describe("_submit_defer_reason", function()
        --- @return agentic.SessionManager
        local function ready_session()
            return {
                session_id = "s-1",
                agent = { state = "ready" },
                _prompt_pending = 0,
                _submit_defer_reason = SessionManager._submit_defer_reason,
            } --[[@as agentic.SessionManager]]
        end

        it("clears a prose submit on a ready idle session", function()
            assert.is_nil(ready_session():_submit_defer_reason("hello"))
        end)

        it("defers while a prompt callback is outstanding", function()
            local session = ready_session()
            session._prompt_pending = 1
            assert.equal("in_flight", session:_submit_defer_reason("hello"))
        end)

        it("defers while a session/load is in flight", function()
            local session = ready_session()
            session._loading = true
            assert.equal("loading", session:_submit_defer_reason("hello"))
        end)

        it("defers before the session is ready", function()
            local session = ready_session()
            session.session_id = nil
            assert.equal("not_ready", session:_submit_defer_reason("hello"))
        end)

        it("defers until the reported usage reset time", function()
            local session = ready_session()
            session._usage_reset_epoch = os.time() + 600
            assert.equal("usage_limited", session:_submit_defer_reason("hello"))
        end)

        -- Without this, disabling auto_continue_on_usage_limit would wedge
        -- every submit forever: no turn can complete normally, so a
        -- clear-on-Stop rule would never fire.
        it("clears once the reset time has passed", function()
            local session = ready_session()
            session._usage_reset_epoch = os.time() - 1
            assert.is_nil(session:_submit_defer_reason("hello"))
        end)
    end)

    describe("_advance_session_epoch", function()
        -- Releasing the counter belongs to the epoch, not to _cancel_session:
        -- a resume advances the epoch without cancelling, and the epoch guard
        -- then refuses the outgoing turn's decrement, so nothing else would
        -- ever bring it back down.
        it("releases the in-flight gate for the outgoing session", function()
            local session = {
                _session_epoch = 3,
                _prompt_pending = 2,
                agent = { state = "ready" },
                session_id = "s-1",
                _advance_session_epoch = SessionManager._advance_session_epoch,
                _set_prompt_pending = SessionManager._set_prompt_pending,
                _sync_modified = function() end,
                _submit_defer_reason = SessionManager._submit_defer_reason,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)

            session:_advance_session_epoch()

            assert.equal(4, session._session_epoch)
            assert.equal(0, session._prompt_pending)
            assert.is_nil(session:_submit_defer_reason("hello"))
        end)
    end)

    describe("permission memory", function()
        local Recovery = require("agentic.session_recovery")
        local SlashCommands = require("agentic.acp.slash_commands")
        local MessageWriter = require("agentic.ui.message_writer")
        local PermissionManager = require("agentic.ui.permission_manager")

        --- @type TestStub[]
        local stubs
        --- @type integer
        local bufnr
        --- @type agentic.SessionManager
        local session

        --- @param tool_call_id string
        --- @return TestSpy callback
        local function request_edit(tool_call_id)
            local cb = spy.new(function() end)
            session.permission_manager:add_request({
                sessionId = "s-1",
                toolCall = {
                    toolCallId = tool_call_id,
                    kind = "edit",
                    rawInput = { file_path = "/tmp/foo.lua" },
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow",
                        kind = "allow_once",
                    },
                    {
                        optionId = "allow-always",
                        name = "Always",
                        kind = "allow_always",
                    },
                },
            }, cb --[[@as function]])
            return cb
        end

        before_each(function()
            stubs = {
                spy.stub(Recovery, "cancel_retry_timer"),
                spy.stub(SlashCommands, "setCommands"),
            }
            bufnr = vim.api.nvim_create_buf(false, true)
            local config_dir = vim.fn.tempname()
            local pm = PermissionManager:new(
                MessageWriter:new(bufnr),
                { agent = bufnr },
                nil,
                function()
                    return config_dir
                end
            )
            table.insert(stubs, spy.stub(pm.permission_float, "open"))
            table.insert(stubs, spy.stub(pm.permission_float, "close"))

            session = {
                session_id = "s-1",
                agent = { stop_generation = function() end },
                status_indicator = { stop = function() end },
                permission_manager = pm,
                widget = {
                    buf_nrs = { input = 0 },
                    set_chat_title = function() end,
                    set_running = function() end,
                    set_idle = function() end,
                },
                stop_generation = SessionManager.stop_generation,
                message_writer = MessageWriter:new(bufnr),
                _cancel_session = SessionManager._cancel_session,
                _reset_conversation = SessionManager._reset_conversation,
                _set_available_commands = SessionManager._set_available_commands,
                render_info = function() end,
                _set_generating = SessionManager._set_generating,
                _update_chat_header = function() end,
                chat_history = ChatHistory:new(),
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)

            request_edit("tc-1")
            pm:_complete_request("allow-always")
        end)

        after_each(function()
            for _, s in ipairs(stubs) do
                s:revert()
            end
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("survives stop_generation", function()
            session:stop_generation()
            local cb = request_edit("tc-2")
            assert.is_true(cb:called_with("allow-once"))
        end)

        it("ends with the session", function()
            session.session_id = nil -- skip the cancel/clear-content block
            session:_cancel_session()
            local cb = request_edit("tc-2")
            assert.spy(cb).was.called(0)
            assert.is_not_nil(session.permission_manager.current_request)
        end)
    end)

    describe("tool call handlers", function()
        local MessageWriter = require("agentic.ui.message_writer")
        local PermissionManager = require("agentic.ui.permission_manager")

        --- @type integer
        local bufnr
        --- @type agentic.SessionManager
        local session
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
            bufnr = vim.api.nvim_create_buf(false, true)
            local writer = MessageWriter:new(bufnr)
            local config_dir = vim.fn.tempname()
            local pm = PermissionManager:new(
                writer,
                { agent = bufnr },
                nil,
                function()
                    return config_dir
                end
            )
            local noop = function() end
            session = {
                message_writer = writer,
                permission_manager = pm,
                chat_history = ChatHistory:new(),
                status_indicator = { reposition = noop, start = noop },
                _held_tool_call_updates = {},
                _loading = false,
                _drain_side_records = noop,
                _drain_subagent_side_records = noop,
                _drain_side_records_of = SessionManager._drain_side_records_of,
                _sync_output_tail = SessionManager._sync_output_tail,
                _view_for = SessionManager._view_for,
                _history_changed = spy.new(noop),
                _try_record_edit_range = noop,
                _record_file_op = noop,
                _on_tool_call = SessionManager._on_tool_call,
                _on_tool_call_update = SessionManager._on_tool_call_update,
                _on_permission_decided = SessionManager._on_permission_decided,
                _sync_job_stop = SessionManager._sync_job_stop,
                _background_job_record = SessionManager._background_job_record,
                _apply_tool_call_fields = SessionManager._apply_tool_call_fields,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            pm.on_decided = function(id, deciders)
                session:_on_permission_decided(id, deciders)
            end
        end)

        after_each(function()
            deferred.revert()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        --- @param id string
        local function tool_call(id)
            session:_on_tool_call({
                tool_call_id = id,
                kind = "execute",
                argument = "grep x f",
                status = "pending",
                shell = "zsh",
            })
        end

        it("records the call's shell in history", function()
            tool_call("tc-1")
            assert.equal("zsh", session.chat_history.messages[1].shell)
        end)

        it("records the fields an update adds in history", function()
            tool_call("tc-1")
            session:_on_tool_call_update({
                tool_call_id = "tc-1",
                status = "failed",
                search_pattern = "x",
                failure_reason = { "denied" },
            })

            local record = session.chat_history.messages[1]
            assert.equal("x", record.search_pattern)
            assert.same({ "denied" }, record.failure_reason)
        end)

        it("keeps recorded fields an update leaves out", function()
            tool_call("tc-1")
            session:_on_tool_call_update({
                tool_call_id = "tc-1",
                status = "completed",
            })

            local record = session.chat_history.messages[1]
            assert.equal("grep x f", record.argument)
            assert.equal("execute", record.kind)
            assert.equal("completed", record.status)
        end)

        describe("a stop of a background job", function()
            local PATH = "/tmp/agentic-test-missing/tasks/b9.output"

            before_each(function()
                session._output_tails = {}
                session._show_final_tail = SessionManager._show_final_tail
            end)

            --- A background command, already ended, as job `b9`.
            --- @param output_file string|nil
            local function background_command(output_file)
                session:_on_tool_call({
                    tool_call_id = "tc-bg",
                    kind = "execute",
                    argument = "tail -f log",
                    description = "Watch the logs",
                    status = "completed",
                    background_job_id = "b9",
                    output_file = output_file,
                    output_ended = true,
                })
            end

            --- @param job_id string
            local function stop(job_id)
                session:_on_tool_call({
                    tool_call_id = "tc-stop",
                    kind = "TaskStop",
                    argument = job_id,
                    status = "in_progress",
                    stopped_job_id = job_id,
                })
            end

            --- @param status agentic.ui.ToolCallStatus
            local function end_stop(status)
                session:_on_tool_call_update({
                    tool_call_id = "tc-stop",
                    status = status,
                })
            end

            --- @param id string
            --- @return agentic.ui.ChatHistory.ToolCall|nil
            local function record_of(id)
                for _, msg in ipairs(session.chat_history.messages) do
                    if msg.type == "tool_call" and msg.tool_call_id == id then
                        return msg
                    end
                end
            end

            --- Whether the job's block footer reads `stopped`.
            --- @return boolean
            local function chat_reads_stopped()
                local writer = session.message_writer
                local _, footer_row =
                    writer:_block_rows(writer.tool_call_blocks["tc-bg"])
                local footer = vim.api.nvim_buf_get_lines(
                    bufnr,
                    footer_row,
                    footer_row + 1,
                    true
                )[1]
                return footer:find("stopped", 1, true) ~= nil
            end

            it("heads the stop with the job and shows its output", function()
                background_command(PATH)
                stop("b9")

                local tracker =
                    session.message_writer.tool_call_blocks["tc-stop"]
                assert.equal("Watch the logs", tracker.argument)
                assert.equal(PATH, tracker.stopped_job_output_file)
                assert.is_nil(tracker.output_file)
                assert.is_nil(session._output_tails["tc-stop"])
                local record = record_of("tc-stop")
                assert.equal("Watch the logs", record.argument)
                assert.equal(PATH, record.stopped_job_output_file)
            end)

            it(
                "marks the job's block stopped once the stop completes",
                function()
                    background_command(PATH)
                    stop("b9")
                    assert.is_nil(record_of("tc-bg").stopped_by)
                    assert.is_false(chat_reads_stopped())

                    end_stop("completed")

                    assert.equal("tc-stop", record_of("tc-bg").stopped_by)
                    assert.equal(
                        "tc-stop",
                        session.message_writer.tool_call_blocks["tc-bg"].stopped_by
                    )
                    assert.is_true(chat_reads_stopped())
                end
            )

            it("leaves the job alone when the stop fails", function()
                background_command(PATH)
                stop("b9")
                end_stop("failed")

                assert.is_nil(record_of("tc-bg").stopped_by)
                assert.is_false(chat_reads_stopped())
            end)

            it("restores the job's head over a later id head", function()
                background_command(PATH)
                stop("b9")
                session:_on_tool_call_update({
                    tool_call_id = "tc-stop",
                    status = "in_progress",
                    argument = "b9",
                })

                assert.equal(
                    "Watch the logs",
                    session.message_writer.tool_call_blocks["tc-stop"].argument
                )
                assert.equal("Watch the logs", record_of("tc-stop").argument)
            end)

            it("keeps the id head for an unknown job", function()
                background_command(PATH)
                stop("zz")
                end_stop("completed")

                local tracker =
                    session.message_writer.tool_call_blocks["tc-stop"]
                assert.equal("zz", tracker.argument)
                assert.is_nil(tracker.stopped_job_output_file)
                assert.is_nil(record_of("tc-bg").stopped_by)
            end)

            it("links a job whose output file is gone", function()
                background_command(nil)
                stop("b9")
                end_stop("completed")

                local tracker =
                    session.message_writer.tool_call_blocks["tc-stop"]
                assert.equal("Watch the logs", tracker.argument)
                assert.is_nil(tracker.stopped_job_output_file)
                assert.equal("tc-stop", record_of("tc-bg").stopped_by)
            end)
        end)

        describe("tool call side records", function()
            --- Make `update` the side record the next drain returns, once.
            --- @param update agentic.ui.MessageWriter.ToolCallBase
            local function record_tool_call(update)
                local sides = { { kind = "tool_call", tool_call = update } }
                session.session_id = "s-1"
                session.destroyed = false
                session._drain_side_records = SessionManager._drain_side_records
                session._apply_side_tool_call =
                    SessionManager._apply_side_tool_call
                session.agent = {
                    drain_side_records = function()
                        local drained = sides
                        sides = {}
                        return drained
                    end,
                } --[[@as agentic.acp.ACPClient]]
            end

            --- Drain `update` as a side record.
            --- @param update agentic.ui.MessageWriter.ToolCallBase
            local function drain_tool_call(update)
                record_tool_call(update)
                session:_drain_side_records()
            end

            --- @type agentic.ui.MessageWriter.ToolCallBase
            local UPDATE = {
                tool_call_id = "tc-msg",
                argument = "peer: Tell peer",
                body = { "hi" },
            }

            local function send_message()
                session:_on_tool_call({
                    tool_call_id = "tc-msg",
                    kind = "SendMessage",
                    argument = "",
                    status = "completed",
                })
            end

            it("adds to a call already in the chat", function()
                send_message()
                drain_tool_call(UPDATE)

                local tracker =
                    session.message_writer.tool_call_blocks["tc-msg"]
                local record = session.chat_history.messages[1]
                for _, message in ipairs({ tracker, record }) do
                    assert.equal("peer: Tell peer", message.argument)
                    assert.same({ "hi" }, message.body)
                    assert.equal("completed", message.status)
                end
            end)

            it("holds an update until its call is in the chat", function()
                drain_tool_call(UPDATE)
                assert.is_nil(session.message_writer.tool_call_blocks["tc-msg"])

                send_message()

                local tracker =
                    session.message_writer.tool_call_blocks["tc-msg"]
                local record = session.chat_history.messages[1]
                for _, message in ipairs({ tracker, record }) do
                    assert.equal("peer: Tell peer", message.argument)
                    assert.same({ "hi" }, message.body)
                end
                assert.same({}, session._held_tool_call_updates)
            end)

            it(
                "reads side records when a call is first reported ended",
                function()
                    record_tool_call(UPDATE)

                    send_message()

                    local tracker =
                        session.message_writer.tool_call_blocks["tc-msg"]
                    assert.equal("peer: Tell peer", tracker.argument)
                end
            )

            it("keeps a subagent's held updates past the turn's end", function()
                record_tool_call(UPDATE)
                session._drain_subagent_side_records =
                    SessionManager._drain_subagent_side_records
                session:_drain_subagent_side_records("a1")
                session._finalize_turn = SessionManager._finalize_turn
                session:_finalize_turn(nil)

                assert.equal(
                    "a1",
                    session._held_tool_call_updates["tc-msg"].child_id
                )
            end)

            it("drops held updates at the turn's end", function()
                drain_tool_call(UPDATE)
                session._finalize_turn = SessionManager._finalize_turn
                session:_finalize_turn(nil)

                assert.same({}, session._held_tool_call_updates)
            end)
        end)

        describe("rejected and ended calls", function()
            local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
            --- @type TestStub[]
            local float_stubs

            before_each(function()
                local noop = function() end
                local pm = session.permission_manager
                float_stubs = {
                    spy.stub(pm.permission_float, "open"),
                    spy.stub(pm.permission_float, "close"),
                }
                session.session_id = "s-1"
                session.destroyed = false
                session.agent = {
                    stop_generation = spy.new(noop),
                } --[[@as agentic.acp.ACPClient]]
                session.status_indicator.stop = noop
                session._set_generating = noop
                session.stop_generation = SessionManager.stop_generation
                session._end_open_tool_calls =
                    SessionManager._end_open_tool_calls
            end)

            after_each(function()
                for _, stub in ipairs(float_stubs) do
                    stub:revert()
                end
            end)

            --- Report an edit outside every grant scope, so no rule decides
            --- it, and open a prompt for it.
            --- @param id string
            local function prompt(id)
                session:_on_tool_call({
                    tool_call_id = id,
                    kind = "edit",
                    argument = "/etc/agentic-test.lua",
                    status = "pending",
                })
                session.permission_manager:add_request({
                    sessionId = "s-1",
                    toolCall = {
                        toolCallId = id,
                        kind = "edit",
                        rawInput = { file_path = "/etc/agentic-test.lua" },
                    },
                    options = {
                        {
                            optionId = "allow-once",
                            name = "Allow",
                            kind = "allow_once",
                        },
                        {
                            optionId = "reject-once",
                            name = "Reject",
                            kind = "reject_once",
                        },
                    },
                }, function() end)
                deferred.drain()
            end

            --- @param id string
            --- @param writer? agentic.ui.MessageWriter default the main writer
            --- @return string|nil
            local function word(id, writer)
                local tracker = (writer or session.message_writer).tool_call_blocks[id]
                return CanonicalToolCall.status_word(tracker)
            end

            --- @param id string
            local function fail(id)
                session:_on_tool_call_update({
                    tool_call_id = id,
                    status = "failed",
                    failure_reason = { "stopped" },
                })
            end

            it("draws a prompt reject as rejected", function()
                prompt("tc-1")
                session.permission_manager:_complete_request("reject-once")
                deferred.drain()
                fail("tc-1")

                assert.equal("rejected", word("tc-1"))
                local text = table.concat(
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                    "\n"
                )
                assert.is_not_nil(
                    text:find(" rejected · prompt-reject", 1, true)
                )
                assert.is_not_nil(text:find("Rejected at the prompt", 1, true))
            end)

            for _, ending in ipairs({ "ends both failed", "leaves both open" }) do
                it(
                    "draws a cancel's prompt rejected and its running call interrupted when the provider "
                        .. ending,
                    function()
                        tool_call("tc-run")
                        session:_on_tool_call_update({
                            tool_call_id = "tc-run",
                            status = "in_progress",
                        })
                        prompt("tc-prompt")

                        session:stop_generation()
                        deferred.drain()
                        if ending == "ends both failed" then
                            fail("tc-run")
                            fail("tc-prompt")
                        else
                            session:_end_open_tool_calls("interrupted")
                        end

                        assert.equal("interrupted", word("tc-run"))
                        assert.equal("rejected", word("tc-prompt"))
                        local records = session.chat_history.messages
                        assert.equal(
                            "interrupted",
                            CanonicalToolCall.status_word(records[1])
                        )
                        assert.equal(
                            "rejected",
                            CanonicalToolCall.status_word(records[2])
                        )
                    end
                )
            end

            it("keeps a failure before the stop failed", function()
                tool_call("tc-1")
                fail("tc-1")
                session:stop_generation()
                assert.equal("failed", word("tc-1"))
            end)

            it("reads a failure after an idle stop as failed", function()
                session:stop_generation()
                tool_call("tc-1")
                fail("tc-1")
                assert.equal("failed", word("tc-1"))
            end)

            it("keeps a stopped call interrupted at another end", function()
                tool_call("tc-1")
                session:stop_generation()
                session:_end_open_tool_calls("max_tokens")
                fail("tc-1")
                assert.equal("interrupted", word("tc-1"))
            end)

            it("keeps the first rejection line", function()
                tool_call("tc-1")
                session:_on_tool_call_update({
                    tool_call_id = "tc-1",
                    status = "failed",
                    rejection = "Rejected by the auto-mode classifier: [X]",
                })
                session:_on_tool_call_update({
                    tool_call_id = "tc-1",
                    status = "failed",
                    rejection = "Rejected by the auto-mode classifier",
                })

                local expected = "Rejected by the auto-mode classifier: [X]"
                assert.equal(
                    expected,
                    session.message_writer.tool_call_blocks["tc-1"].rejection
                )
                assert.equal(
                    expected,
                    session.chat_history.messages[1].rejection
                )
            end)

            it("draws a prompt withdrawn without a stop as rejected", function()
                prompt("tc-1")
                -- What a respawn or a provider switch does to open prompts.
                session.permission_manager:cancel_requests()
                deferred.drain()

                assert.equal("rejected", word("tc-1"))
                assert.same(
                    { "prompt-cancel" },
                    session.chat_history.messages[1].decided_by
                )
            end)

            describe("of a subagent", function()
                local child_buf
                --- @type agentic.ui.MessageWriter
                local child_writer
                --- @type agentic.ui.MessageWriter
                local other_writer
                --- @type agentic.Subagents
                local subagents

                before_each(function()
                    local noop = function() end
                    child_buf = vim.api.nvim_create_buf(false, true)
                    child_writer = MessageWriter:new(child_buf)
                    other_writer = MessageWriter:new(child_buf)
                    subagents = session._subagents
                    for child_id, writer in pairs({
                        c1 = child_writer,
                        c2 = other_writer,
                    }) do
                        subagents._agents[child_id] = {
                            open = true,
                            record_read = true,
                            transcript = {
                                bufnr = child_buf,
                                view = {
                                    writer = writer,
                                    status_indicator = {
                                        reposition = noop,
                                        start = noop,
                                        stop = noop,
                                        switch = noop,
                                    },
                                },
                                set_running = noop,
                                set_context = noop,
                                is_loaded = function()
                                    return true
                                end,
                            },
                        } --[[@as agentic.Subagents.Agent]]
                    end
                    subagents._agent_block = function()
                        return { subagent = { mode = "blocking" } }
                    end
                    subagents._write_row = noop
                    subagents._host.sync_modified = noop
                    subagents._host.end_side_records = noop
                    subagents._tool_call_owner["sub-1"] = "c1"
                    subagents._tool_call_owner["sub-2"] = "c2"
                    child_writer:write_tool_call_block({
                        tool_call_id = "sub-1",
                        kind = "execute",
                        argument = "sleep 10",
                        status = "in_progress",
                    })
                    other_writer:write_tool_call_block({
                        tool_call_id = "sub-2",
                        kind = "execute",
                        argument = "sleep 20",
                        status = "in_progress",
                    })
                end)

                after_each(function()
                    vim.api.nvim_buf_delete(child_buf, { force = true })
                end)

                it(
                    "reads a foreground call failed at the main cancel as interrupted",
                    function()
                        session:stop_generation()
                        fail("sub-1")
                        assert.equal("interrupted", word("sub-1", child_writer))
                    end
                )

                it(
                    "leaves a background subagent's calls out of a main cancel",
                    function()
                        subagents._agent_block = function()
                            return { subagent = { mode = "background" } }
                        end
                        session:stop_generation()
                        fail("sub-1")
                        assert.equal("failed", word("sub-1", child_writer))
                    end
                )

                it("marks only the stopped subagent's calls", function()
                    subagents:stop("c1")

                    assert.equal(
                        "interrupted",
                        child_writer.tool_call_blocks["sub-1"].ended_as
                    )
                    assert.is_nil(
                        other_writer.tool_call_blocks["sub-2"].ended_as
                    )
                    assert
                        .spy(session.agent.stop_generation).was
                        .called_with(session.agent, "c1")
                end)

                for _, case in ipairs({
                    {
                        state = { state = "idle", stopReason = "max_tokens" },
                        word = "max_tokens",
                    },
                    { state = { state = "idle" }, word = "ended" },
                    { state = { state = "failed" }, word = "failed" },
                }) do
                    it("ends its open calls " .. case.word, function()
                        subagents:end_agent("c1", case.state)
                        assert.equal(case.word, word("sub-1", child_writer))
                    end)
                end

                it("leaves its open calls open at an unknown end", function()
                    subagents:end_agent("c1", { state = "unknown" })
                    assert.equal("in_progress", word("sub-1", child_writer))
                end)

                describe("ended by the cancel", function()
                    local CANCELLED =
                        { state = "idle", stopReason = "cancelled" }

                    before_each(function()
                        session:stop_generation()
                    end)

                    it(
                        "reads interrupted when the close comes first",
                        function()
                            fail("sub-1")
                            subagents:end_agent("c1", CANCELLED)
                            assert.equal(
                                "interrupted",
                                word("sub-1", child_writer)
                            )
                        end
                    )

                    it("reads interrupted when the end comes first", function()
                        subagents:end_agent("c1", CANCELLED)
                        fail("sub-1")
                        assert.equal("interrupted", word("sub-1", child_writer))
                    end)

                    it(
                        "keeps a stopped call interrupted at another end",
                        function()
                            subagents:end_agent("c1", { state = "idle" })
                            assert.equal(
                                "interrupted",
                                word("sub-1", child_writer)
                            )
                        end
                    )
                end)
            end)

            it(
                "queues the closed folds of a replayed rejected block",
                function()
                    session.message_writer:write_tool_call_block(
                        ChatHistory.to_tool_call_block({
                            type = "tool_call",
                            tool_call_id = "tc-1",
                            kind = "execute",
                            argument = "rm -rf build",
                            status = "failed",
                            decided_by = { "prompt-reject" },
                            failure_reason = { "No.", "Stop." },
                        })
                    )

                    local states = vim.tbl_map(function(op)
                        return op.open
                    end, session.message_writer._pending_fold_ops)
                    assert.same({ false, false }, states)
                end
            )
        end)

        it("records no rendering state in history", function()
            tool_call("tc-1")
            local record = session.chat_history.messages[1] --[[@as table]]
            assert.is_nil(record.extmark_id)
            assert.is_nil(record.decoration_extmark_ids)
        end)

        it("keeps switch_mode and todowrite bodies in history", function()
            for i, kind in ipairs({ "switch_mode", "TodoWrite" }) do
                session:_on_tool_call({
                    tool_call_id = "tc-" .. kind,
                    kind = kind,
                    argument = kind,
                    status = "pending",
                    body = { "line 1", "line 2" },
                })
                assert.same(
                    { "line 1", "line 2" },
                    session.chat_history.messages[i].body
                )
            end
        end)

        describe("read range", function()
            before_each(function()
                session:_on_tool_call({
                    tool_call_id = "tc-read",
                    kind = "read",
                    argument = "Read /tmp/f.lua",
                    status = "pending",
                })
            end)

            it("splits the range off an update's argument", function()
                session:_on_tool_call_update({
                    tool_call_id = "tc-read",
                    status = "in_progress",
                    argument = "/tmp/f.lua (10 - 19)",
                })

                local tracker =
                    session.message_writer.tool_call_blocks["tc-read"]
                local record = session.chat_history.messages[1]
                for _, message in ipairs({ tracker, record }) do
                    assert.equal("/tmp/f.lua", message.argument)
                    assert.same({ offset = 10, limit = 10 }, message.read_range)
                end
            end)

            it("takes a newer update's range over the tracker's", function()
                session:_on_tool_call_update({
                    tool_call_id = "tc-read",
                    status = "in_progress",
                    argument = "/tmp/f.lua (10 - 19)",
                })
                session:_on_tool_call_update({
                    tool_call_id = "tc-read",
                    status = "in_progress",
                    argument = "/tmp/f.lua (30 - 39)",
                })

                assert.same(
                    { offset = 30, limit = 10 },
                    session.message_writer.tool_call_blocks["tc-read"].read_range
                )
            end)
        end)

        it("renders a later fenced execute body single-fenced", function()
            tool_call("tc-1")
            session:_on_tool_call_update({
                tool_call_id = "tc-1",
                status = "in_progress",
                body = { "first" },
            })
            session:_on_tool_call_update({
                tool_call_id = "tc-1",
                status = "completed",
                body = { "```console", "second", "```" },
            })

            assert.same(
                { "first", "", "---", "", "second" },
                session.message_writer.tool_call_blocks["tc-1"].body
            )
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local i_second = vim.fn.index(lines, "second")
            assert.equal("```", lines[i_second + 2])
        end)

        --- @return string footer The last line of the chat that holds a status
        local function footer()
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            for i = #lines, 1, -1 do
                if lines[i]:find("pending") then
                    return lines[i]
                end
            end
            return ""
        end

        it("shows deciders recorded before the block arrives", function()
            session.permission_manager:record_deciders("tc-1", { "read-only" })
            tool_call("tc-1")
            deferred.drain()

            assert.truthy(footer():find("pending · read-only", 1, true))
            assert.same(
                { "read-only" },
                session.chat_history.messages[1].decided_by
            )
            assert.is_nil(session.permission_manager:take_deciders("tc-1"))
        end)

        it("updates the footer and history for a later verdict", function()
            tool_call("tc-1")
            assert.is_nil(footer():find("·", 1, true))

            session.permission_manager:record_deciders("tc-1", { "grant" })
            deferred.drain()

            assert.truthy(footer():find("pending · grant", 1, true))
            assert.same(
                { "grant" },
                session.chat_history.messages[1].decided_by
            )
        end)

        it(
            "does not redraw or save a verdict the block already shows",
            function()
                session.permission_manager:record_deciders("tc-1", { "grant" })
                tool_call("tc-1")
                local save = spy.new(function() end)
                session._history_changed = save --[[@as function]]
                deferred.drain()

                assert.equal(0, save.call_count)
            end
        )

        it("ignores a verdict that lands after the session ends", function()
            tool_call("tc-1")
            session.permission_manager:record_deciders("tc-1", { "grant" })
            session.destroyed = true
            deferred.drain()

            assert.is_nil(footer():find("·", 1, true))
            assert.is_nil(session.chat_history.messages[1].decided_by)
        end)
    end)

    describe("submit gating", function()
        --- @param close_gate fun(sm: agentic.SessionManager)|nil Puts the
        ---        session into the state under test
        --- @return agentic.SessionManager, table
        local function gated(close_gate)
            local sink = { inner = 0, stopped = 0, actions = {} }
            local session = {
                session_id = "s-1",
                agent = { state = "ready" },
                _prompt_pending = 0,
                message_writer = {
                    write_error_action = function(_self, text)
                        table.insert(sink.actions, text)
                    end,
                },
                stop_generation = function()
                    sink.stopped = sink.stopped + 1
                end,
                _handle_input_submit_inner = function()
                    sink.inner = sink.inner + 1
                end,
                _submit_defer_reason = SessionManager._submit_defer_reason,
                _handle_input_submit = SessionManager._handle_input_submit,
                _submit_hold_reason = SessionManager._submit_hold_reason,
            }
            --- @type agentic.SessionManager
            local typed = session
            if close_gate then
                close_gate(typed)
            end
            return typed, sink
        end

        -- The provider takes a mid-turn prompt as a turn of its own and runs it
        -- after the current one, so an ordinary submit needs no force to go out
        -- — and must not cancel what is running to do it.
        it("sends past a running turn, leaving it alone", function()
            local session, sink = gated(function(sm)
                sm._prompt_pending = 1
            end)

            assert.is_true(session:_handle_input_submit("hi"))

            assert.equal(0, sink.stopped)
            assert.equal(1, sink.inner)
        end)

        it("sends past a usage limit only when forced", function()
            local session, sink = gated(function(sm)
                sm._usage_reset_epoch = os.time() + 600
            end)

            assert.is_false(session:_handle_input_submit("hi"))
            assert.equal(0, sink.inner)

            assert.is_true(session:_handle_input_submit("hi", { force = true }))

            assert.equal(0, sink.stopped)
            assert.equal(1, sink.inner)
        end)

        -- There is no session to send into, so forcing would hand send_prompt
        -- a nil id and lose the text: ChatWidget treats a dispatch as consumed
        -- and deletes it from the input buffer.
        it("still defers when there is no session to send to", function()
            local gates = {
                not_ready = function(sm)
                    sm.session_id = nil
                end,
                loading = function(sm)
                    sm._loading = true
                end,
            }
            for _, close_gate in pairs(gates) do
                local session, sink = gated(close_gate)

                assert.is_false(
                    session:_handle_input_submit("hi", { force = true })
                )

                assert.equal(0, sink.inner)
                assert.equal("hi", session._pending_bufferless_prompt)
            end
        end)

        -- A local command needs no provider round-trip, so it answers under
        -- every gate, including a usage limit no force was given for.
        it("dispatches a local command under a closed gate", function()
            local session, sink = gated(function(sm)
                sm._usage_reset_epoch = os.time() + 600
            end)

            assert.is_true(session:_handle_input_submit("/context"))

            assert.equal(1, sink.inner)
        end)

        -- A held prompt with no buffer range has nothing on screen to show for
        -- it, so the reason has to be said.
        it("writes why a bufferless prompt was held", function()
            local session, sink = gated(function(sm)
                sm.session_id = nil
            end)

            session:_handle_input_submit("hi")

            assert.equal(1, #sink.actions)
            assert.is_true(sink.actions[1]:find("held") ~= nil)
        end)

        it("says nothing for a buffer submit, which is tagged", function()
            local session, sink = gated(function(sm)
                sm.session_id = nil
            end)

            session:_handle_input_submit("hi", { from_buffer = true })

            assert.equal(0, #sink.actions)
            assert.is_nil(session._pending_bufferless_prompt)
        end)
    end)

    describe("block sequencing", function()
        local dispatch_spy
        local new_session_spy
        local grant_spy
        local delete_spy
        local context_spy
        local rename_spy
        local errors
        local session
        --- Block texts still tagged in the input buffer, in dispatch order.
        local queued
        --- @type tests.helpers.Deferred
        local deferred

        --- @param head string The block that dispatches now
        --- @param texts string[] What the queue holds after it
        local function submit(head, texts)
            queued = texts
            session:_handle_input_submit_inner(head)
            -- A local command's continuation is scheduled, so the sequence
            -- advances a tick after the command answers.
            deferred.drain()
        end

        before_each(function()
            local noop = function() end

            deferred = Deferred.capture()
            local empty = function()
                return true
            end

            errors = {}
            dispatch_spy = spy.new(noop)
            context_spy = spy.new(noop)
            grant_spy = spy.new(noop)
            delete_spy = spy.new(noop)
            rename_spy = spy.new(noop)
            new_session_spy = spy.new(function(this)
                -- What _cancel_session leaves behind: no session to send into,
                -- so the gate holds the next block until one is created.
                this.session_id = nil
            end)

            session = {
                session_id = "s-1",
                id = 1,
                _is_first_message = false,
                _prompt_pending = 0,
                agent = { state = "ready", provider_config = { name = "Test" } },
                message_writer = {
                    write_user_prompt = noop,
                    write_error_action = function(_self, text)
                        table.insert(errors, text)
                    end,
                },
                chat_history = { title = "existing", add_message = noop },
                _history_changed = noop,
                widget = {
                    buf_nrs = { input = 0 },
                    set_idle = noop,
                    set_chat_title = noop,
                    input_dispatch = {
                        next_queued_block = function()
                            local text = queued[1]
                            return text and { text = text, sr = 0, er = 0 }
                        end,
                        consume_queued_block = function()
                            local text = table.remove(queued, 1)
                            return text and { text = text, sr = 0, er = 0 }
                        end,
                        queued_block_count = function()
                            return #queued
                        end,
                        cancel_queue = function()
                            for i = #queued, 1, -1 do
                                table.remove(queued, i)
                            end
                        end,
                    },
                },
                todo_list = { close_if_all_completed = noop },
                code_selection = { is_empty = empty },
                file_list = { is_empty = empty },
                diagnostics_list = { is_empty = empty },
                new_session = new_session_spy,
                _display_context_usage = context_spy,
                _grant_command = { run = grant_spy },
                _delete_session = delete_spy,
                _rename_session = rename_spy,
                _dispatch_turn = dispatch_spy,
                _submit_defer_reason = SessionManager._submit_defer_reason,
                _run_local_command = SessionManager._run_local_command,
                _drain_queue = SessionManager._drain_queue,
                _truncate_queue = SessionManager._truncate_queue,
                _confirm_queued_command = SessionManager._confirm_queued_command,
                _handle_input_submit = SessionManager._handle_input_submit,
                _submit_hold_reason = SessionManager._submit_hold_reason,
                _handle_input_submit_inner = SessionManager._handle_input_submit_inner,
                _send_user_prompt = SessionManager._send_user_prompt,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            deferred.revert()
        end)

        -- A synchronously-answered command reaches no Stop, so the sequence
        -- would stall there if the drain waited for a turn to end.
        it("dispatches the next block after a synchronous command", function()
            submit("/context", { "then do X" })

            assert.equal(1, context_spy.call_count)
            assert.spy(dispatch_spy).was.called(1)
            assert.equal(0, #queued)
        end)

        -- The submit that dispatched the command has not deleted its own lines
        -- yet, and consuming the next block edits the rows it is about to
        -- delete by number. So the continuation waits for the next tick.
        it("does not drain inside the command's own dispatch", function()
            queued = { "then do X" }

            session:_handle_input_submit_inner("/context")

            assert.equal(1, #queued)
            assert.spy(dispatch_spy).was.called(0)

            deferred.drain()

            assert.equal(0, #queued)
            assert.spy(dispatch_spy).was.called(1)
        end)

        -- A command's argument stops at its own line, so the block queued
        -- behind it can never end up inside the argument.
        it("keeps a command's argument on its own line", function()
            submit("/rename a b", { "then do X" })

            assert.equal("a b", rename_spy.calls[1][2])
            assert.spy(dispatch_spy).was.called(1)
            assert.equal(0, #queued)
        end)

        it("passes a grant scope without the block behind it", function()
            submit("/grant root", { "Also do X" })

            assert.equal("root", grant_spy.calls[1][2])
        end)

        -- The confirm belongs to the drain path only: as a submit's own first
        -- block the user typed /new *as* the message.
        it("does not confirm /new as a submit's first block", function()
            local confirm = spy.stub(vim.fn, "confirm")

            submit("/new", { "Start on X" })

            assert.equal(0, confirm.call_count)
            assert.equal(1, new_session_spy.call_count)
            confirm:revert()
        end)

        it("holds the next block until /new has a session again", function()
            submit("/new", { "Start on X" })

            assert.equal(1, new_session_spy.call_count)
            assert.spy(dispatch_spy).was.called(0)
            assert.equal(1, #queued)

            -- The session-created edge, where the gate clears.
            session.session_id = "s-2"
            session:_drain_queue()

            assert.spy(dispatch_spy).was.called(1)
            assert.equal(0, #queued)
        end)

        -- The picker outlives the call, so dispatching now would race a dialog
        -- the user is still answering.
        it("waits for an async command's dialog to resolve", function()
            submit("/grant", { "Also do X" })

            assert.equal(1, grant_spy.call_count)
            assert.spy(dispatch_spy).was.called(0)

            -- The scope question is settled: on_done resumes the sequence.
            grant_spy.calls[1][3]()
            deferred.drain()

            assert.spy(dispatch_spy).was.called(1)
        end)

        describe("/delete", function()
            local confirm_stub, find_files_stub, delete_file_stub, notify_stub

            before_each(function()
                session._delete_session = SessionManager._delete_session
                session._cancel_session = function(this)
                    this.session_id = nil
                end
                session._advance_session_epoch = function() end
                confirm_stub = spy.stub(vim.fn, "confirm")
                find_files_stub = spy.stub(ChatHistory, "find_files")
                find_files_stub:returns({ "/saved/sid.json" })
                delete_file_stub = spy.stub(os, "remove")
                delete_file_stub:returns(true)
                notify_stub = spy.stub(Logger, "notify")
            end)

            after_each(function()
                confirm_stub:revert()
                find_files_stub:revert()
                delete_file_stub:revert()
                notify_stub:revert()
            end)

            it("truncates the sequence once confirmed", function()
                confirm_stub:returns(1)

                submit("/delete", { "foo", "bar" })

                assert.equal(1, delete_file_stub.call_count)
                assert.same(
                    { "/saved/sid.json", n = 1 },
                    delete_file_stub.calls[1]
                )
                assert.spy(dispatch_spy).was.called(0)
                assert.equal(0, #queued)
                assert.is_true(errors[1]:match("^/delete: 2 queued") ~= nil)
            end)

            it("removes every copy of the session file", function()
                confirm_stub:returns(1)
                find_files_stub:returns({ "/a/sid.json", "/b/sid.json" })

                submit("/delete", {})

                assert.same(
                    { "/a/sid.json", "/b/sid.json" },
                    vim.tbl_map(function(call)
                        return call[1]
                    end, delete_file_stub.calls)
                )
            end)

            it("reports a copy that cannot be removed", function()
                confirm_stub:returns(1)
                find_files_stub:returns({ "/a/sid.json", "/b/sid.json" })
                delete_file_stub:invokes(function(path)
                    if path == "/b/sid.json" then
                        return false, "Permission denied"
                    end
                    return true
                end)
                local written = spy.new(function() end)
                session.message_writer.write_message = written
                session._finalize_turn = function() end

                submit("/delete", {})

                assert.equal("s-1", session.session_id)
                local text = written.calls[1][2].content.text
                assert.truthy(
                    text:find("/b/sid.json: Permission denied", 1, true)
                )
                assert.truthy(text:find("removed 1 of 2 files", 1, true))
            end)

            it("reports a session with no saved file", function()
                confirm_stub:returns(1)
                find_files_stub:returns({})
                local written = spy.new(function() end)
                session.message_writer.write_message = written
                session._finalize_turn = function() end

                submit("/delete", {})

                assert.equal(0, delete_file_stub.call_count)
                local text = written.calls[1][2].content.text
                assert.truthy(
                    text:find("No saved file for this session", 1, true)
                )
            end)

            it("resumes the sequence when declined", function()
                confirm_stub:returns(2)

                submit("/delete", { "foo", "bar" })

                assert.equal(0, delete_file_stub.call_count)
                assert.spy(dispatch_spy).was.called(1)
                assert.equal(1, #queued)
                assert.equal(0, #errors)
            end)
        end)

        -- One block per turn: a prose head takes its own turn and the drain
        -- that follows its Stop takes the next block.
        it("dispatches one block per turn", function()
            submit("Do X", { "/compact", "then Y" })

            assert.spy(dispatch_spy).was.called(1)
            assert.equal(2, #queued)
        end)
    end)

    describe("_drain_queue", function()
        --- @param queued string|nil Text of the queue's next block
        --- @param gate agentic.SubmitDeferReason|nil
        local function drainable(queued, gate)
            local block = queued and { text = queued, sr = 0, er = 0 }
            local sm
            sm = {
                consumed = false,
                cancelled = false,
                inner_spy = spy.new(function() end),
                message_writer = { write_error_action = function() end },
                widget = {
                    input_dispatch = {
                        next_queued_block = function()
                            return block
                        end,
                        queued_block_count = function()
                            return 1
                        end,
                        -- Returns what it deleted, as the real one does: the
                        -- drain dispatches that rather than the block it read
                        -- first.
                        consume_queued_block = function()
                            sm.consumed = true
                            return block
                        end,
                        cancel_queue = function()
                            sm.cancelled = true
                        end,
                    },
                },
                _submit_defer_reason = function()
                    return gate
                end,
                _confirm_queued_command = SessionManager._confirm_queued_command,
                _drain_queue = SessionManager._drain_queue,
            }
            return sm
        end

        --- @param sm table
        local function run(sm)
            sm._handle_input_submit_inner = sm.inner_spy
            return sm:_drain_queue()
        end

        it("dispatches the next block when no gate is active", function()
            local sm = drainable("queued text", nil)

            assert.is_true(run(sm))

            assert.is_true(sm.consumed)
            assert.spy(sm.inner_spy).was.called(1)
            assert.equal("queued text", sm.inner_spy.calls[1][2])
        end)

        -- The block must stay tagged and visible: consuming it first and
        -- finding the gate closed afterwards would eat the text.
        it("leaves the block tagged while the gate is closed", function()
            local sm = drainable("x", "usage_limited")

            assert.is_false(run(sm))

            assert.is_false(sm.consumed)
            assert.spy(sm.inner_spy).was.called(0)
        end)

        it("does nothing when the queue is empty", function()
            local sm = drainable(nil, nil)

            assert.is_false(run(sm))

            assert.spy(sm.inner_spy).was.called(0)
        end)

        -- A queued /new is pasted data as often as it is intent, and running
        -- it destroys the session it was pasted into.
        it("confirms a session-ending command and runs it on yes", function()
            local sm = drainable("/new", nil)
            local confirm = spy.stub(vim.fn, "confirm")
            confirm:returns(1)

            assert.is_true(run(sm))

            assert.equal(1, confirm.call_count)
            assert.is_true(sm.consumed)
            assert.spy(sm.inner_spy).was.called(1)
            confirm:revert()
        end)

        it("drops the whole queue when the command is declined", function()
            local sm = drainable("/new", nil)
            local confirm = spy.stub(vim.fn, "confirm")
            confirm:returns(2)

            assert.is_false(run(sm))

            assert.is_true(sm.cancelled)
            assert.is_false(sm.consumed)
            assert.spy(sm.inner_spy).was.called(0)
            confirm:revert()
        end)

        it("does not confirm an ordinary command block", function()
            local sm = drainable("/compact", nil)
            local confirm = spy.stub(vim.fn, "confirm")

            assert.is_true(run(sm))

            assert.equal(0, confirm.call_count)
            confirm:revert()
        end)
    end)

    describe("_dispatch_deferred_prompts", function()
        -- Regression: sending the retained prompt must not ALSO drain the
        -- region queue in the same tick — that fires a second concurrent
        -- send_prompt (the retained prompt's own Stop drains the regions).
        it("sends the retained prompt without also draining", function()
            local submit_spy = spy.new(function() end)
            local drained = false
            local sm = {
                _pending_bufferless_prompt = "hi",
                _submit_defer_reason = function()
                    return nil
                end,
                _handle_input_submit = submit_spy,
                _drain_queue = function()
                    drained = true
                    return true
                end,
                _dispatch_deferred_prompts = SessionManager._dispatch_deferred_prompts,
            }

            sm:_dispatch_deferred_prompts()

            assert.spy(submit_spy).was.called(1)
            assert.equal("hi", submit_spy.calls[1][2])
            assert.is_nil(sm._pending_bufferless_prompt)
            assert.is_false(drained)
        end)

        -- Resubmitting blind would retain it again and append a second
        -- deferral notice, since write_error_action appends unconditionally.
        it("leaves a still-gated prompt retained and unannounced", function()
            local submit_spy = spy.new(function() end)
            local sm = {
                _pending_bufferless_prompt = "hi",
                _submit_defer_reason = function()
                    return "usage_limited"
                end,
                _handle_input_submit = submit_spy,
                _drain_queue = function()
                    error("should not drain while the prompt is retained")
                end,
                _dispatch_deferred_prompts = SessionManager._dispatch_deferred_prompts,
            }

            assert.is_false(sm:_dispatch_deferred_prompts())

            assert.spy(submit_spy).was.called(0)
            assert.equal("hi", sm._pending_bufferless_prompt)
        end)

        it("drains queued regions when nothing is retained", function()
            local drained = false
            local sm = {
                _pending_bufferless_prompt = nil,
                _submit_defer_reason = function()
                    return nil
                end,
                _handle_input_submit = function()
                    error("should not submit with nothing retained")
                end,
                _drain_queue = function()
                    drained = true
                    return false
                end,
                _dispatch_deferred_prompts = SessionManager._dispatch_deferred_prompts,
            }

            sm:_dispatch_deferred_prompts()

            assert.is_true(drained)
        end)
    end)

    describe("_sync_history_context", function()
        --- @param agent_info? agentic.acp.AgentInfo
        --- @param recorded_version? string
        --- @return agentic.SessionManager
        local function make_session(agent_info, recorded_version)
            return {
                chat_history = { provider_version = recorded_version },
                agent = {
                    agent_info = agent_info,
                    provider_name = "opencode-acp",
                },
                file_activity = { serialize = function() end },
                config_options = { current_model_id = function() end },
                _sync_history_context = SessionManager._sync_history_context,
            } --[[@as agentic.SessionManager]]
        end

        it("records the session's provider, not the default", function()
            local session = make_session(nil)
            assert.are_not.equal("opencode-acp", Config.provider)

            session:_sync_history_context(session.chat_history)

            assert.equal("opencode-acp", session.chat_history.provider)
        end)

        it("records the version the agent reported", function()
            local session = make_session({ name = "acp", version = "0.66.0" })

            session:_sync_history_context(session.chat_history)

            assert.equal("0.66.0", session.chat_history.provider_version)
        end)

        it("keeps a saved version when the agent reports none", function()
            local session = make_session(nil, "0.65.0")

            session:_sync_history_context(session.chat_history)

            assert.equal("0.65.0", session.chat_history.provider_version)
        end)
    end)

    describe("_persist_history", function()
        --- @param saves table Collects each history that reached `save`
        --- @return agentic.SessionManager
        local function make_session(saves)
            return with_subagents({
                chat_history = {
                    session_id = "current",
                    save = function(this)
                        table.insert(saves, this)
                    end,
                    has_prompt = function()
                        return true
                    end,
                },
                agent = { agent_info = { name = "acp", version = "0.66.0" } },
                widget = { buf_nrs = {} },
                file_activity = { serialize = function() end },
                config_options = { current_model_id = function() end },
                _sync_history_context = SessionManager._sync_history_context,
                _persist_history = SessionManager._persist_history,
                _sync_modified = SessionManager._sync_modified,
                _set_prompt_pending = SessionManager._set_prompt_pending,
            } --[[@as agentic.SessionManager]])
        end

        -- A turn callback holds the history captured at dispatch, which the
        -- session may since have swapped for another.
        it("syncs the history it was handed", function()
            local saves = {}
            local session = make_session(saves)
            local captured = {
                session_id = "captured",
                save = session.chat_history.save,
                has_prompt = session.chat_history.has_prompt,
            }

            session:_persist_history(captured)

            assert.equal("0.66.0", captured.provider_version)
            assert.is_nil(session.chat_history.provider_version)
            assert.equal("captured", saves[1].session_id)
        end)

        it("writes nothing before a session exists", function()
            local saves = {}
            local session = make_session(saves)
            session.chat_history.session_id = nil

            session:_persist_history(session.chat_history)

            assert.equal(0, #saves)
        end)

        it("writes nothing before the user's first prompt", function()
            local saves = {}
            local session = make_session(saves)
            session.chat_history.has_prompt = function()
                return false
            end

            session:_persist_history(session.chat_history)

            assert.equal(0, #saves)
        end)
    end)

    describe("_on_session_update: agent_message_chunk", function()
        local ResponseBoundary = require("agentic.acp.response_boundary")

        --- @type agentic.SessionManager
        local session
        --- @type TestSpy
        local main_write
        --- @type TestSpy
        local subagent_write
        --- @type TestSpy
        local indicator_start
        --- @type TestSpy
        local drain
        --- `"drain"` per hook record drain and the text of each main-writer
        --- write, in call order.
        --- @type string[]
        local main_calls
        --- The task id each update is tagged with.
        --- @type table<agentic.acp.AgentMessageChunk, string>
        local tags = {}

        before_each(function()
            main_calls = {}
            main_write = spy.new(function(_, update)
                table.insert(main_calls, update.content.text)
            end)
            subagent_write = spy.new(function() end)
            indicator_start = spy.new(function() end)
            drain = spy.new(function()
                table.insert(main_calls, "drain")
            end)
            local noop = function() end
            -- A running subagent with task id `task`.
            local transcript = {
                view = setmetatable({
                    writer = { write_message_chunk = subagent_write },
                    status_indicator = { reposition = noop, switch = noop },
                    response_boundary = ResponseBoundary:new(),
                }, { __index = AgentView }),
                set_modified = noop,
            }
            session = setmetatable({
                main_view = setmetatable({
                    writer = { write_message_chunk = main_write },
                    status_indicator = {
                        start = indicator_start,
                        reposition = noop,
                    },
                    response_boundary = ResponseBoundary:new(),
                }, { __index = AgentView }),
                chat_history = ChatHistory:new(),
                agent = {
                    provider_config = { name = "test-provider" },
                    subagent_task_id = function(_, update)
                        return tags[update]
                    end,
                },
                widget = { buf_nrs = {} },
                _prompt_pending = 1,
                _drain_side_records = drain,
            }, { __index = SessionManager }) --[[@as agentic.SessionManager]]
            with_subagents(session)
            session._subagents._agents.c1 =
                { transcript = transcript, open = true, record_read = true }
            session._subagents._agent_by_task = { task = "c1" }
            session._subagents.transcript = function()
                return transcript
            end
        end)

        --- @param message_id string|vim.NIL
        --- @param text string
        --- @param task_id string|nil Tags the chunk as subagent content
        --- @return agentic.acp.AgentMessageChunk
        local function chunk(message_id, text, task_id)
            --- @type agentic.acp.AgentMessageChunk
            local update = {
                sessionUpdate = "agent_message_chunk",
                content = { type = "text", text = text },
                messageId = message_id,
            }
            tags[update] = task_id
            return update
        end

        --- `{ text, starts_response }` of each call a writer received.
        --- @param write TestSpy
        --- @return { [1]: string, [2]: boolean }[]
        local function writes(write)
            local out = {}
            for _, call in ipairs(write.calls) do
                table.insert(out, { call[2].content.text, call[3] })
            end
            return out
        end

        it("marks the first text of a new response", function()
            session:_on_session_update(chunk("X", "reviewer."))
            session:_on_session_update(chunk(vim.NIL, " more"))
            session:_on_session_update(chunk("Y", "\n"))
            session:_on_session_update(chunk("Y", "Next"))

            assert.same({
                { "reviewer.", false },
                { " more", false },
                { "Next", true },
            }, writes(main_write))
            assert.equal(
                "reviewer. more\n\nNext",
                session.chat_history.messages[1].text
            )
        end)

        it("leaves the update it was given unchanged", function()
            session:_on_session_update(chunk("X", "a"))
            local update = chunk("Y", "\nb")

            session:_on_session_update(update)

            assert.equal("\nb", update.content.text)
        end)

        it("tracks subagent responses apart from the main agent's", function()
            session:_on_session_update(chunk("X", "main"))
            session:_on_session_update(chunk("S1", "sub", "task"))
            session:_on_session_update(chunk("S2", "next", "task"))

            assert.same({ { "main", false } }, writes(main_write))
            assert.same(
                { { "sub", false }, { "next", true } },
                writes(subagent_write)
            )
            assert.equal(1, #session.chat_history.messages)
        end)

        it("drains hook records before a new response's text", function()
            session:_on_session_update(chunk("X", "first"))
            session:_on_session_update(chunk("Y", "reply"))

            assert.same({ "first", "drain", "reply" }, main_calls)
        end)

        it("does not drain at a subagent's new response", function()
            session:_on_session_update(chunk("S1", "sub", "task"))
            session:_on_session_update(chunk("S2", "next", "task"))

            assert.equal(0, drain.call_count)
        end)

        it("does not drain while the session loads", function()
            session._loading = true
            session:_on_session_update(chunk("X", "first"))
            session:_on_session_update(chunk("Y", "reply"))

            assert.equal(0, drain.call_count)
        end)

        it("writes a thought chunk unfiltered", function()
            session:_on_session_update(chunk("X", "answer"))
            --- @type agentic.acp.AgentThoughtChunk
            local thought = {
                sessionUpdate = "agent_thought_chunk",
                content = { type = "text", text = "\nhm" },
                messageId = "Y",
            }

            session:_on_session_update(thought)

            assert.same(
                { { "answer", false }, { "\nhm", nil } },
                writes(main_write)
            )
            assert.equal("thinking", indicator_start.calls[2][2])
            assert.equal("thought", session.chat_history.messages[2].type)
        end)
    end)

    describe("output tails", function()
        local FileTail = require("agentic.utils.file_tail")
        local PATH = "/tmp/tasks/bg.output"

        --- @type TestStub
        local start_stub
        --- @type TestStub
        local read_stub
        --- @type { stop: TestSpy, on_rows: fun(rows: string[]) }[]
        local tails
        --- @type agentic.SessionManager
        local session
        --- @type TestSpy
        local set_output_tail

        before_each(function()
            tails = {}
            start_stub = spy.stub(FileTail, "new")
            start_stub:invokes(function(_self, _path, _max_lines, on_rows)
                local tail =
                    { stop = spy.new(function() end), on_rows = on_rows }
                table.insert(tails, tail)
                -- As the real tail does, before returning.
                on_rows({ "row" })
                return tail
            end)
            read_stub = spy.stub(FileSystem, "read_last_lines")
            read_stub:returns({ "row" })
            set_output_tail = spy.new(function(writer, id, _rows, live)
                writer.tool_call_blocks[id].output_live = live
            end)
            session = {
                _output_tails = {},
                message_writer = {
                    bufnr = vim.api.nvim_get_current_buf(),
                    tool_call_blocks = {},
                    set_output_tail = set_output_tail,
                },
                widget = { clear = function() end },
                _sync_modified = function() end,
                _view_for = SessionManager._view_for,
                _sync_output_tail = SessionManager._sync_output_tail,
                _show_final_tail = SessionManager._show_final_tail,
                _stop_output_tails = SessionManager._stop_output_tails,
                clear_chat = SessionManager.clear_chat,
            } --[[@as agentic.SessionManager]]
            with_subagents(session)
            session.message_writer.reset = function() end
        end)

        after_each(function()
            start_stub:revert()
            read_stub:revert()
        end)

        --- @param id string
        --- @param fields table|nil
        local function track(id, fields)
            session.message_writer.tool_call_blocks[id] = vim.tbl_extend(
                "force",
                { tool_call_id = id, status = "completed" },
                fields or {}
            )
        end

        --- The `rows` and `live` of each `set_output_tail` call.
        --- @return table[]
        local function shown()
            return vim.tbl_map(function(call)
                return { call[3], call[4] }
            end, set_output_tail.calls)
        end

        it("does nothing without an output file", function()
            track("tc-1")
            session:_sync_output_tail("tc-1")

            assert.equal(0, start_stub.call_count)
            assert.equal(0, set_output_tail.call_count)
        end)

        it("starts on an output file, once", function()
            track("tc-1", { output_file = PATH })
            session:_sync_output_tail("tc-1")
            session:_sync_output_tail("tc-1")

            assert.equal(1, start_stub.call_count)
            assert.same({ { { "row" }, true } }, shown())

            tails[1].on_rows({ "a", "b" })
            assert.same({ "a", "b" }, shown()[2][1])
        end)

        it("ends the tail on output_ended", function()
            track("tc-1", { output_file = PATH })
            session:_sync_output_tail("tc-1")
            session.message_writer.tool_call_blocks["tc-1"].output_ended = true
            session:_sync_output_tail("tc-1")

            assert.equal(1, tails[1].stop.call_count)
            assert.is_nil(session._output_tails["tc-1"])
            assert.same({ { "row" }, false }, shown()[2])
        end)

        it("leaves a final tail alone on later updates", function()
            track("tc-1", { output_file = PATH, output_ended = true })
            session:_sync_output_tail("tc-1")
            session:_sync_output_tail("tc-1")

            assert.equal(1, set_output_tail.call_count)
        end)

        it("shows the rows as final when the tail cannot start", function()
            local notify_stub = spy.stub(Logger, "notify")
            MiniTest.finally(function()
                notify_stub:revert()
            end)
            start_stub:invokes(function()
                return nil, "boom"
            end)
            track("tc-1", { output_file = PATH })
            session:_sync_output_tail("tc-1")

            assert.equal(1, notify_stub.call_count)
            assert.same({ { { "row" }, false } }, shown())
            assert.is_nil(session._output_tails["tc-1"])
        end)

        it("ignores rows while the buffer is unloaded", function()
            local buf = vim.api.nvim_create_buf(false, true)
            session.message_writer.bufnr = buf
            track("tc-1", { output_file = PATH })
            session:_sync_output_tail("tc-1")
            vim.api.nvim_buf_delete(buf, { unload = true })

            tails[1].on_rows({ "late" })
            assert.equal(1, set_output_tail.call_count)
        end)

        it("reads once when ended on arrival", function()
            track("tc-1", { output_file = PATH, output_ended = true })
            session:_sync_output_tail("tc-1")

            assert.equal(0, start_stub.call_count)
            assert.same({ { { "row" }, false } }, shown())
        end)

        it("shows no rows for a missing file", function()
            read_stub:returns(nil)
            track("tc-1", { output_file = PATH, output_ended = true })
            session:_sync_output_tail("tc-1")

            assert.same({ { {}, false } }, shown())
        end)

        it("ignores rows after the block is gone", function()
            track("tc-1", { output_file = PATH })
            session:_sync_output_tail("tc-1")
            session.message_writer.tool_call_blocks["tc-1"] = nil

            tails[1].on_rows({ "late" })
            assert.equal(1, set_output_tail.call_count)
        end)

        it("stops every tail on clear_chat", function()
            track("tc-1", { output_file = PATH })
            track("tc-2", { output_file = PATH })
            session:_sync_output_tail("tc-1")
            session:_sync_output_tail("tc-2")
            set_output_tail:reset()

            session:clear_chat()

            assert.equal(1, tails[1].stop.call_count)
            assert.equal(1, tails[2].stop.call_count)
            assert.same({}, session._output_tails)
            assert.equal(0, set_output_tail.call_count)
        end)

        it("finalises every tail on disconnect", function()
            track("tc-1", { output_file = PATH })
            session:_sync_output_tail("tc-1")

            session:_stop_output_tails(true)

            assert.equal(1, tails[1].stop.call_count)
            assert.same({ { "row" }, false }, shown()[2])
        end)
    end)
end)
