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
            local session = {
                _title_user_set = user_renamed,
                chat_history = {
                    title = current_title,
                    save = save_spy,
                },
                widget = {
                    set_chat_title = set_title_spy,
                },
                _sync_history_context = function() end,
                _on_session_update = SessionManager._on_session_update,
            } --[[@as agentic.SessionManager]]
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
                spy.stub(Recovery, "remove_reauth_keymap"),
                spy.stub(Recovery, "cancel_health_check_timer"),
                spy.stub(Recovery, "cancel_retry_timer"),
                spy.stub(SlashCommands, "setCommands"),
            }

            local session = {
                session_id = nil, -- skip the cancel/clear-content block
                _title_user_set = true, -- as if the user had /rename'd
                permission_manager = { clear = function() end },
                widget = {
                    buf_nrs = { input = 0 },
                    set_chat_title = function() end,
                },
                _cancel_session = SessionManager._cancel_session,
            } --[[@as agentic.SessionManager]]

            session:_cancel_session()

            assert.is_false(session._title_user_set)

            for _, s in ipairs(stubs) do
                s:revert()
            end
        end)

        it("resets is_generating and stops indicators on reset mid-turn", function()
            local Recovery = require("agentic.session_recovery")
            local SlashCommands = require("agentic.acp.slash_commands")
            local stubs = {
                spy.stub(Recovery, "remove_reauth_keymap"),
                spy.stub(Recovery, "cancel_health_check_timer"),
                spy.stub(Recovery, "cancel_retry_timer"),
                spy.stub(SlashCommands, "setCommands"),
            }

            local noop = function() end
            local status_stop = spy.new(noop)
            local subagent_stop = spy.new(noop)
            local session = {
                session_id = "live-session", -- exercise the teardown block
                is_generating = true, -- as if a turn were streaming
                agent = { cancel_session = noop },
                permission_manager = { clear = noop },
                todo_list = { clear = noop },
                file_list = { clear = noop },
                code_selection = { clear = noop },
                diagnostics_list = { clear = noop },
                config_options = { clear = noop },
                status_indicator = { stop = status_stop },
                subagent_status_indicator = { stop = subagent_stop },
                widget = {
                    buf_nrs = { input = 0 },
                    clear = noop,
                    set_chat_title = noop,
                },
                _cancel_session = SessionManager._cancel_session,
            } --[[@as agentic.SessionManager]]

            session:_cancel_session()

            assert.is_false(session.is_generating)
            assert.spy(status_stop).was.called(1)
            assert.spy(subagent_stop).was.called(1)

            for _, s in ipairs(stubs) do
                s:revert()
            end
        end)
    end)

    describe("_on_session_update: usage_update budget", function()
        --- @param fields table|nil Extra usage_update fields (cost, _meta)
        --- @return agentic.acp.UsageUpdate
        local function usage_update(fields)
            return vim.tbl_extend("force", {
                sessionUpdate = "usage_update",
                used = 1000,
                size = 200000,
            }, fields or {}) --[[@as agentic.acp.UsageUpdate]]
        end

        --- @return agentic.SessionManager
        local function make_session()
            return {
                _update_chat_header = function() end,
                _on_session_update = SessionManager._on_session_update,
                _budget_status = SessionManager._budget_status,
            } --[[@as agentic.SessionManager]]
        end

        it("captures _meta rate-limit into _budget", function()
            local session = make_session()

            session:_on_session_update(usage_update({
                _meta = {
                    ["_claude/rateLimit"] = {
                        rateLimitType = "five_hour",
                        utilization = 0.5,
                        resetsAt = os.time() + 9000,
                    },
                },
            }))

            assert.equal("five_hour", session._budget.rateLimitType)
            assert.equal(0.5, session._budget.utilization)
        end)

        it("keeps prior _budget when the update has no _meta", function()
            local session = make_session()
            session._budget = { rateLimitType = "five_hour" }

            session:_on_session_update(usage_update())

            assert.equal("five_hour", session._budget.rateLimitType)
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

        it("clears _budget on session reset (/new, /clear)", function()
            local Recovery = require("agentic.session_recovery")
            local SlashCommands = require("agentic.acp.slash_commands")
            local stubs = {
                spy.stub(Recovery, "remove_reauth_keymap"),
                spy.stub(Recovery, "cancel_health_check_timer"),
                spy.stub(Recovery, "cancel_retry_timer"),
                spy.stub(SlashCommands, "setCommands"),
            }

            local session = {
                session_id = nil, -- skip the cancel/clear-content block
                _budget = { rateLimitType = "five_hour" },
                permission_manager = { clear = function() end },
                widget = {
                    buf_nrs = { input = 0 },
                    set_chat_title = function() end,
                },
                _cancel_session = SessionManager._cancel_session,
                _budget_status = SessionManager._budget_status,
            } --[[@as agentic.SessionManager]]

            session:_cancel_session()

            assert.is_nil(session._budget)
            assert.is_nil(session:_budget_status())

            for _, s in ipairs(stubs) do
                s:revert()
            end
        end)
    end)

    describe("_budget_status", function()
        --- @param budget agentic.acp.RateLimitInfo|nil
        --- @return agentic.SessionManager
        local function make_session(budget)
            return {
                _budget = budget,
                _budget_status = SessionManager._budget_status,
            } --[[@as agentic.SessionManager]]
        end

        it("on pace at half window: overshoot ≈ 1.0", function()
            local session = make_session({
                rateLimitType = "five_hour",
                utilization = 0.5,
                resetsAt = os.time() + 2.5 * 3600,
            })

            local util, overshoot = session:_budget_status()

            assert.equal(0.5, util)
            assert.is_true(math.abs(overshoot - 1.0) < 0.01)
        end)

        it("too fast: 90% used at 20% elapsed → overshoot > 1", function()
            local session = make_session({
                rateLimitType = "five_hour",
                utilization = 0.9,
                resetsAt = os.time() + 4 * 3600,
            })

            local _, overshoot = session:_budget_status()

            assert.is_true(overshoot > 1)
        end)

        it("no verdict at the top of a fresh window (frac < 0.05)", function()
            local session = make_session({
                rateLimitType = "five_hour",
                utilization = 0.1,
                resetsAt = os.time() + 5 * 3600 - 1,
            })

            local util, overshoot = session:_budget_status()

            assert.equal(0.1, util)
            assert.is_nil(overshoot)
        end)

        it("normalises 0–100 utilization to a fraction", function()
            local session = make_session({
                rateLimitType = "five_hour",
                utilization = 50,
                resetsAt = os.time() + 2.5 * 3600,
            })

            local util = session:_budget_status()

            assert.equal(0.5, util)
        end)

        it("normalises millisecond resetsAt", function()
            local session = make_session({
                rateLimitType = "five_hour",
                utilization = 0.5,
                resetsAt = (os.time() + 2.5 * 3600) * 1000,
            })

            local util, overshoot = session:_budget_status()

            assert.equal(0.5, util)
            assert.is_true(math.abs(overshoot - 1.0) < 0.01)
        end)

        it(
            "steady-state event without utilization: resets only",
            function()
                -- Real observed payload: status "allowed" carries no
                -- utilization; overageStatus "rejected" = no overage credits.
                local session = make_session({
                    status = "allowed",
                    rateLimitType = "five_hour",
                    resetsAt = os.time() + 3600,
                    overageStatus = "rejected",
                    isUsingOverage = false,
                })

                local util, overshoot, resets = session:_budget_status()

                assert.is_nil(util)
                assert.is_nil(overshoot)
                assert.is_not_nil(resets)
            end
        )

        it("bails to nil when rateLimitType is missing", function()
            local session = make_session({
                utilization = 0.5,
                resetsAt = os.time() + 3600,
            })

            assert.is_nil(session:_budget_status())
        end)

        it("overage: utilization but no pace verdict", function()
            local session = make_session({
                rateLimitType = "overage",
                utilization = 0.3,
                resetsAt = os.time() + 3600,
            })

            local util, overshoot = session:_budget_status()

            assert.equal(0.3, util)
            assert.is_nil(overshoot)
        end)

        it("isUsingOverage suppresses the pace verdict", function()
            local session = make_session({
                rateLimitType = "five_hour",
                utilization = 0.9,
                resetsAt = os.time() + 4 * 3600,
                isUsingOverage = true,
            })

            local util, overshoot = session:_budget_status()

            assert.equal(0.9, util)
            assert.is_nil(overshoot)
        end)

        it("nil budget → nil", function()
            assert.is_nil(make_session(nil):_budget_status())
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
                status_indicator = { start = noop, stop = noop },
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
                _apply_default_trust = noop,
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

    describe("announce_model_loaded", function()
        --- @param models table<string, agentic.acp.ConfigOption.Option>
        local function make_session(models)
            local write_spy = spy.new(function() end)
            local session = {
                _announced_model_id = nil,
                config_options = {
                    get_model = function(_, id)
                        return models[id]
                    end,
                    legacy_agent_models = {
                        get_model = function() end,
                    },
                },
                message_writer = { write_message = write_spy },
                announce_model_loaded = SessionManager.announce_model_loaded,
            } --[[@as agentic.SessionManager]]
            return session, write_spy
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

        it("extracts real model from description for Default name", function()
            local session, write_spy = make_session({
                ["default"] = {
                    value = "default",
                    name = "Default (recommended)",
                    description = "Opus 4.8 with 1M context window.",
                },
            })

            session:announce_model_loaded("default")

            assert.equal(
                "**Loaded Opus** · default\nOpus 4.8 with 1M context window.",
                written_text(write_spy, 1)
            )
        end)

        it("falls back to the id when the model is unknown", function()
            local session, write_spy = make_session({})

            session:announce_model_loaded("ghost-model")

            assert.equal("**Loaded ghost-model** · ghost-model", written_text(write_spy, 1))
        end)

        it("suppresses a consecutive duplicate id", function()
            local session, write_spy = make_session({
                ["m"] = { value = "m", name = "M", description = "desc" },
            })

            session:announce_model_loaded("m")
            session:announce_model_loaded("m")

            assert.spy(write_spy).was.called(1)
        end)

        it("ignores nil model id", function()
            local session, write_spy = make_session({})

            session:announce_model_loaded(nil)

            assert.spy(write_spy).was.called(0)
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

        it("drains queued prompts to the new provider in on_created", function()
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

            local handle_input_spy = spy.new(function() end)
            local captured_on_created
            local new_session_spy = spy.new(function(_self, opts)
                captured_on_created = opts.on_created
            end)

            Config.provider = "target-provider"

            local session = {
                is_generating = false,
                session_id = "old-session",
                _queued_prompts = { "message one", "message two" },

                agent = {
                    cancel_session = spy.new(function() end),
                    provider_config = { name = "Old" },
                },
                permission_manager = { clear = function() end },
                todo_list = { clear = function() end },
                chat_history = { messages = {}, session_id = "old" },
                _is_first_message = false,
                _history_to_send = nil,
                _handle_input_submit = handle_input_spy,
                new_session = new_session_spy,
                switch_provider = SessionManager.switch_provider,
            } --[[@as agentic.SessionManager]]

            session:switch_provider()

            -- on_created should have been captured
            assert.is_not_nil(captured_on_created)

            -- Simulate the new session being created
            session.chat_history = {
                messages = {},
                session_id = "new-session",
                timestamp = os.time(),
            }
            captured_on_created()

            -- Verify _handle_input_submit was called with combined prompts
            -- calls[1] = {self, combined_text} (method call via `:` syntax)
            assert.spy(handle_input_spy).was.called(1)
            assert.equal("message one\n\nmessage two", handle_input_spy.calls[1][2])

            -- Verify _queued_prompts was cleared by cancel_retry_timer
            assert.is_nil(session._queued_prompts)
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
                status_indicator = { start = function() end },
                _show_diff_in_buffer = function() end,
                chat_history = { update_tool_call = function() end },
                _tool_call_owner = {},
                _writer_for = SessionManager._writer_for,
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
                    write_user_prompt = noop,
                    write_error_message = function()
                        return nil, nil
                    end,
                    finalize_turn = noop,
                    set_turn_usage = noop,
                    scroll_to_bottom = noop,
                    is_near_bottom = empty,
                    tool_call_blocks = {},
                },
                subagent_writer = { finalize_turn = noop },
                status_indicator = { start = noop, stop = noop },
                subagent_status_indicator = { stop = noop },
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
                    drain_queued_regions = function()
                        return nil
                    end,
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
                _sync_history_context = SessionManager._sync_history_context,
                _drain_queue = SessionManager._drain_queue,
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

    describe("send_prompt error dispatch", function()
        local Recovery = require("agentic.session_recovery")
        --- @type TestStub
        local reauth_stub
        --- @type TestStub
        local respawn_stub
        --- @type TestStub
        local auto_continue_stub
        --- @type TestStub
        local schedule_stub

        before_each(function()
            reauth_stub = spy.stub(Recovery, "offer_reauth")
            respawn_stub = spy.stub(Recovery, "respawn_after_usage_limit")
            auto_continue_stub = spy.stub(Recovery, "offer_auto_continue")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            reauth_stub:revert()
            respawn_stub:revert()
            auto_continue_stub:revert()
            schedule_stub:revert()
        end)

        --- Minimal session whose send_prompt errors and whose
        --- write_error_message reports the given class.
        --- @param error_type string|nil
        --- @return agentic.SessionManager
        local function make_session(error_type)
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
                _retry_attempt = 0,
                agent = {
                    state = "ready",
                    provider_config = { name = "Test" },
                    send_prompt = function(_self, _sid, _prompt, cb)
                        cb(nil, { message = "boom" })
                    end,
                },
                message_writer = {
                    write_message = noop,
                    write_user_prompt = noop,
                    write_error_message = function()
                        return error_type, nil
                    end,
                    finalize_turn = noop,
                    set_turn_usage = noop,
                    scroll_to_bottom = noop,
                    is_near_bottom = empty,
                    tool_call_blocks = {},
                },
                subagent_writer = { finalize_turn = noop },
                status_indicator = { start = noop, stop = noop },
                subagent_status_indicator = { stop = noop },
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
                    drain_queued_regions = function()
                        return nil
                    end,
                },
                permission_manager = { current_request = nil, queue = {} },
                todo_list = { close_if_all_completed = noop },
                file_list = { is_empty = empty },
                code_selection = { is_empty = empty },
                diagnostics_list = { is_empty = empty },
                _ring_bell = noop,
                _handle_input_submit = SessionManager._handle_input_submit,
                _handle_input_submit_inner = SessionManager._handle_input_submit_inner,
                _notify_attention = SessionManager._notify_attention,
                _sync_history_context = SessionManager._sync_history_context,
                _drain_queue = SessionManager._drain_queue,
            } --[[@as agentic.SessionManager]]
        end

        it("billing_error offers no reauth, respawn or auto-continue", function()
            local session = make_session("billing_error")
            session:_handle_input_submit("hello")
            assert.spy(reauth_stub).was.called(0)
            assert.spy(respawn_stub).was.called(0)
            assert.spy(auto_continue_stub).was.called(0)
        end)

        it("authentication_error offers reauth", function()
            local session = make_session("authentication_error")
            session:_handle_input_submit("hello")
            assert.spy(reauth_stub).was.called(1)
            assert.spy(respawn_stub).was.called(0)
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
                tab_page_id = 1,
                _destroyed = false,
                status_indicator = { start = noop, stop = noop },
                message_writer = { tool_call_blocks = {} },
                _tool_call_owner = {},
                _writer_for = SessionManager._writer_for,
                -- nil chat window => unfocused => bell would ring if notified
                widget = { win_nrs = { chat = nil } },
                permission_manager = {
                    add_request = function()
                        return prompted
                    end,
                },
                _notify_attention = SessionManager._notify_attention,
                _on_request_permission = SessionManager._on_request_permission,
            } --[[@as agentic.SessionManager]]
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

        before_each(function()
            SessionManagerModule = require("agentic.session_manager")

            select_stub = spy.stub(vim.ui, "select")
            input_stub = spy.stub(vim.ui, "input")
            notify_stub = spy.stub(Logger, "notify")
            git_root_stub = spy.stub(vim.fs, "root")
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
                    finalize_turn = spy.new(function() end),
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

    describe("subagent Task tracking", function()
        --- @type TestSpy
        local start_spy
        --- @type TestSpy
        local stop_spy
        --- @type TestSpy
        local close_win_spy
        --- @type TestSpy
        local divider_spy
        --- @type TestSpy
        local enable_numbering_spy
        local orig_auto_close

        --- @return agentic.SessionManager
        local function make_session()
            start_spy = spy.new(function() end)
            stop_spy = spy.new(function() end)
            close_win_spy = spy.new(function() end)
            divider_spy = spy.new(function() end)
            enable_numbering_spy = spy.new(function() end)
            return {
                _open_tasks = {},
                _task_ordinal = {},
                _next_ordinal = 0,
                _numbering_latched = false,
                subagent_status_indicator = {
                    start = start_spy,
                    stop = stop_spy,
                },
                subagent_writer = {
                    emit_divider = divider_spy,
                    enable_numbering = enable_numbering_spy,
                },
                widget = { close_subagent_window = close_win_spy },
                _ensure_subagent_window = function() end,
                _ordinal_for = SessionManager._ordinal_for,
                _maybe_latch_numbering = SessionManager._maybe_latch_numbering,
                _mark_task_open = SessionManager._mark_task_open,
                _mark_task_closed = SessionManager._mark_task_closed,
            } --[[@as agentic.SessionManager]]
        end

        before_each(function()
            orig_auto_close = Config.windows.subagent.auto_close
        end)

        after_each(function()
            Config.windows.subagent.auto_close = orig_auto_close
        end)

        it("marks a task open, starts the indicator", function()
            local session = make_session()
            session:_mark_task_open("task-1")

            assert.is_true(session._open_tasks["task-1"])
            assert.spy(start_spy).was.called(1)
        end)

        it("open is idempotent (repeat calls don't restart)", function()
            local session = make_session()
            session:_mark_task_open("task-1")
            session:_mark_task_open("task-1")

            assert.spy(start_spy).was.called(1)
        end)

        it("stops the indicator only when the last task closes", function()
            local session = make_session()
            session:_mark_task_open("task-1")
            session:_mark_task_open("task-2")

            session:_mark_task_closed("task-1")
            assert.spy(stop_spy).was.called(0)

            session:_mark_task_closed("task-2")
            assert.spy(stop_spy).was.called(1)
        end)

        it("close is idempotent — a duplicated terminal update is harmless", function()
            local session = make_session()
            session:_mark_task_open("task-1")
            session:_mark_task_open("task-2")

            -- task-1 closes twice (e.g. consolidated + PostToolUse update)
            session:_mark_task_closed("task-1")
            session:_mark_task_closed("task-1")

            -- sibling still open, so the indicator must not have stopped
            assert.spy(stop_spy).was.called(0)
            assert.is_true(session._open_tasks["task-2"])
            -- membership guard also protects the divider: closed once, not twice
            assert.spy(divider_spy).was.called(1)
        end)

        it("emits one divider per closing task", function()
            local session = make_session()
            session:_mark_task_open("task-1")
            session:_mark_task_open("task-2")

            session:_mark_task_closed("task-1")
            session:_mark_task_closed("task-2")

            -- each finished subagent gets its own separator (emit_divider itself
            -- no-ops when nothing was written since the last one)
            assert.spy(divider_spy).was.called(2)
        end)

        it("auto-closes the split on last close when configured", function()
            Config.windows.subagent.auto_close = true
            local session = make_session()
            session:_mark_task_open("task-1")
            session:_mark_task_closed("task-1")

            assert.spy(close_win_spy).was.called(1)
        end)

        it("leaves the split open when auto_close is off", function()
            Config.windows.subagent.auto_close = false
            local session = make_session()
            session:_mark_task_open("task-1")
            session:_mark_task_closed("task-1")

            assert.spy(close_win_spy).was.called(0)
        end)

        it("assigns ordinals in first-seen order, idempotent per agent", function()
            local session = make_session()
            assert.equal(0, session:_ordinal_for("task-a"))
            assert.equal(1, session:_ordinal_for("task-b"))
            -- same agent again keeps its number
            assert.equal(0, session:_ordinal_for("task-a"))
            assert.equal(2, session:_ordinal_for("task-c"))
        end)

        it("latches numbering once two tasks run concurrently", function()
            local session = make_session()
            session:_mark_task_open("task-1")
            assert.spy(enable_numbering_spy).was.called(0)

            session:_mark_task_open("task-2")
            assert.is_true(session._numbering_latched)
            assert.spy(enable_numbering_spy).was.called(1)
        end)

        it("stays latched when the count drops back to one", function()
            local session = make_session()
            session:_mark_task_open("task-1")
            session:_mark_task_open("task-2")
            session:_mark_task_closed("task-1")

            -- a later single task must not re-trigger the backfill
            session:_maybe_latch_numbering()
            assert.spy(enable_numbering_spy).was.called(1)
            assert.is_true(session._numbering_latched)
        end)
    end)

    describe("subagent numbering integration", function()
        local MessageWriter = require("agentic.ui.message_writer")
        local Renderer = require("agentic.ui.tool_call_renderer")
        --- @type integer
        local sub_bufnr
        --- @type integer
        local sub_winid

        local function decoration_signs()
            local marks = vim.api.nvim_buf_get_extmarks(
                sub_bufnr,
                Renderer.NS_DECORATIONS,
                0,
                -1,
                { details = true }
            )
            local signs = {}
            for _, m in ipairs(marks) do
                table.insert(signs, m[4].sign_text)
            end
            return signs
        end

        local function count(signs, value)
            local n = 0
            for _, s in ipairs(signs) do
                if s == value then
                    n = n + 1
                end
            end
            return n
        end

        --- @param id string
        --- @param parent string
        --- @return agentic.ui.MessageWriter.ToolCallBlock
        local function child_call(id, parent)
            return {
                tool_call_id = id,
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = { "output" },
                parent_tool_use_id = parent,
            }
        end

        local function make_session()
            sub_bufnr = vim.api.nvim_create_buf(false, true)
            sub_winid = vim.api.nvim_open_win(sub_bufnr, false, {
                relative = "editor",
                width = 60,
                height = 20,
                row = 0,
                col = 0,
            })
            local noop = function() end
            local indicator = { start = noop, stop = noop, reposition = noop }
            return {
                message_writer = { write_tool_call_block = noop, reposition = noop },
                subagent_writer = MessageWriter:new(sub_bufnr),
                status_indicator = indicator,
                subagent_status_indicator = indicator,
                widget = {
                    open_subagent_window = noop,
                    close_subagent_window = noop,
                },
                chat_history = { add_message = noop },
                _tool_call_owner = {},
                _open_tasks = {},
                _task_ordinal = {},
                _next_ordinal = 0,
                _numbering_latched = false,
                _ensure_subagent_window = noop,
                _try_record_edit_range = noop,
                _track_plan_exit = noop,
                _writer_for = SessionManager._writer_for,
                _indicator_for = SessionManager._indicator_for,
                _ordinal_for = SessionManager._ordinal_for,
                _maybe_latch_numbering = SessionManager._maybe_latch_numbering,
                _mark_task_open = SessionManager._mark_task_open,
                _on_tool_call = SessionManager._on_tool_call,
            } --[[@as agentic.SessionManager]]
        end

        after_each(function()
            if sub_winid and vim.api.nvim_win_is_valid(sub_winid) then
                vim.api.nvim_win_close(sub_winid, true)
            end
            if sub_bufnr and vim.api.nvim_buf_is_valid(sub_bufnr) then
                vim.api.nvim_buf_delete(sub_bufnr, { force = true })
            end
        end)

        it("numbers both when children render before the second task opens", function()
            local session = make_session()
            -- both agents' children stream before either kind-resolving update
            session:_mark_task_open("task-a")
            session:_on_tool_call(child_call("c-a", "task-a"), false)
            session:_on_tool_call(child_call("c-b", "task-b"), false)
            -- second task's kind resolves → latch flips, backfills both
            session:_mark_task_open("task-b")

            -- full rail: both blocks' borders replaced by their own digit
            assert.equal(0, count(decoration_signs(), "│ "))
            assert.is_true(count(decoration_signs(), "0 ") > 0)
            assert.is_true(count(decoration_signs(), "1 ") > 0)
        end)

        it("numbers both when the second child renders after the latch", function()
            local session = make_session()
            session:_mark_task_open("task-a")
            session:_on_tool_call(child_call("c-a", "task-a"), false)
            session:_mark_task_open("task-b") -- flip, backfill c-a
            session:_on_tool_call(child_call("c-b", "task-b"), false) -- live

            -- full rail: both blocks' borders replaced by their own digit
            assert.equal(0, count(decoration_signs(), "│ "))
            assert.is_true(count(decoration_signs(), "0 ") > 0)
            assert.is_true(count(decoration_signs(), "1 ") > 0)
        end)
    end)

    describe("_apply_default_trust", function()
        --- @type table
        local pm
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr
        local orig_auto, orig_trust_tmp

        before_each(function()
            local SessionManagerModule = require("agentic.session_manager")
            test_bufnr = vim.api.nvim_create_buf(false, true)
            orig_auto = Config.auto_approve_trust_scope
            orig_trust_tmp = Config.permissions.trust_tmp
            Config.auto_approve_trust_scope = true
            Config.permissions.trust_tmp = true

            pm = {
                get_trust_scope = spy.new(function()
                    return nil
                end),
                set_trust_scope = spy.new(function() end),
            }
            session = {
                tab_page_id = vim.api.nvim_get_current_tabpage(),
                permission_manager = pm,
                widget = {
                    buf_nrs = { chat = test_bufnr },
                    tab_page_id = vim.api.nvim_get_current_tabpage(),
                },
                _push_trust_to_headers = SessionManagerModule._push_trust_to_headers,
                _apply_default_trust = SessionManagerModule._apply_default_trust,
            } --[[@as agentic.SessionManager]]
        end)

        after_each(function()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
            vim.t.agentic_headers = nil
            Config.auto_approve_trust_scope = orig_auto
            Config.permissions.trust_tmp = orig_trust_tmp
        end)

        it("activates a tmp scope when both flags are on and none is set", function()
            session:_apply_default_trust()
            assert.equal(1, pm.set_trust_scope.call_count)
            local scope = pm.set_trust_scope.calls[1][2]
            assert.equal("tmp", scope.kind)
        end)

        it("leaves a user-set scope untouched", function()
            pm.get_trust_scope = spy.new(function()
                return { kind = "repo" }
            end)
            session:_apply_default_trust()
            assert.equal(0, pm.set_trust_scope.call_count)
        end)

        it("does nothing when trust_tmp is off", function()
            Config.permissions.trust_tmp = false
            session:_apply_default_trust()
            assert.equal(0, pm.set_trust_scope.call_count)
        end)

        it("does nothing when auto_approve_trust_scope is off", function()
            Config.auto_approve_trust_scope = false
            session:_apply_default_trust()
            assert.equal(0, pm.set_trust_scope.call_count)
        end)
    end)

    describe("_drain_queue", function()
        it("dispatches queued regions when no gate is active", function()
            local submit_spy = spy.new(function() end)
            local drained = false
            local sm = {
                _retry_timer = nil,
                widget = {
                    drain_queued_regions = function()
                        drained = true
                        return "queued text"
                    end,
                },
                _handle_input_submit = submit_spy,
            }
            SessionManager._drain_queue(sm)
            assert.is_true(drained)
            assert.spy(submit_spy).was.called(1)
            assert.equal("queued text", submit_spy.calls[1][2])
        end)

        it("leaves regions tagged while a retry timer is armed", function()
            local drained = false
            local submit_spy = spy.new(function() end)
            local sm = {
                _retry_timer = 123,
                widget = {
                    drain_queued_regions = function()
                        drained = true
                        return "x"
                    end,
                },
                _handle_input_submit = submit_spy,
            }
            SessionManager._drain_queue(sm)
            assert.is_false(drained)
            assert.spy(submit_spy).was.called(0)
        end)

        it("does nothing when the queue is empty", function()
            local submit_spy = spy.new(function() end)
            local sm = {
                _retry_timer = nil,
                widget = {
                    drain_queued_regions = function()
                        return nil
                    end,
                },
                _handle_input_submit = submit_spy,
            }
            SessionManager._drain_queue(sm)
            assert.spy(submit_spy).was.called(0)
        end)
    end)

    describe("_flush_pending_input", function()
        -- Regression: flushing pending text must not ALSO drain the region
        -- queue in the same tick — that fires a second concurrent send_prompt
        -- (the flushed turn's own Stop drains the regions instead).
        it("submits pending text without also draining", function()
            local inner_spy = spy.new(function() end)
            local drained = false
            local sm = {
                _pending_input = "hi",
                _handle_input_submit_inner = inner_spy,
                _drain_queue = SessionManager._drain_queue,
                _retry_timer = nil,
                widget = {
                    drain_queued_regions = function()
                        drained = true
                        return "regions"
                    end,
                },
                _handle_input_submit = function() end,
            }
            SessionManager._flush_pending_input(sm)
            assert.spy(inner_spy).was.called(1)
            assert.is_false(drained)
        end)

        it("drains queued regions when there is no pending text", function()
            local drained = false
            local sm = {
                _pending_input = nil,
                _handle_input_submit_inner = function()
                    error("should not submit with no pending input")
                end,
                _drain_queue = SessionManager._drain_queue,
                _retry_timer = nil,
                widget = {
                    drain_queued_regions = function()
                        drained = true
                        return nil
                    end,
                },
                _handle_input_submit = function() end,
            }
            SessionManager._flush_pending_input(sm)
            assert.is_true(drained)
        end)
    end)
end)
