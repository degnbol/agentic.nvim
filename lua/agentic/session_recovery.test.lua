--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, need-check-nil, undefined-field, param-type-mismatch, return-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Recovery = require("agentic.session_recovery")

describe("agentic.session_recovery", function()
    describe("auto-continue after a usage limit", function()
        --- @type TestSpy
        local submit_spy

        --- @param dispatched boolean Whether the user left something held,
        ---        which then supplies the continuation
        --- @return agentic.SessionManager
        local function session_with(dispatched)
            submit_spy = spy.new(function() end)
            return {
                session_id = "s1",
                destroyed = false,
                _retry_attempt = 1,
                _usage_reset_epoch = os.time() + 600,
                _handle_input_submit = submit_spy,
                _dispatch_deferred_prompts = function()
                    return dispatched
                end,
            } --[[@as agentic.SessionManager]]
        end

        it("sends 'continue' when nothing was queued", function()
            local session = session_with(false)

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(1)
            assert.equal("continue", submit_spy.calls[1][2])
        end)

        -- Whatever was held IS the continuation, whether that is a tagged
        -- region or a retained bufferless prompt; an extra "continue" would
        -- fire a second concurrent turn in front of it.
        it("sends no 'continue' when something was held", function()
            local session = session_with(true)

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(0)
        end)

        -- The gate must open first, or it would defer both branches above and
        -- the pause would never end.
        it("releases the usage gate before dispatching", function()
            local session = session_with(false)
            local epoch_at_submit
            session._handle_input_submit = spy.new(function(sm)
                epoch_at_submit = sm._usage_reset_epoch
            end)

            Recovery._fire_auto_continue(session)

            assert.is_nil(epoch_at_submit)
            assert.is_nil(session._usage_reset_epoch)
        end)

        -- cancel_retry_timer(sm, false) spares the attempt counter. Resetting
        -- it would stop offer_auto_continue's MAX_RETRIES check from ever
        -- tripping, retrying every 130s indefinitely.
        it("keeps the attempt counter so a repeat limit backs off", function()
            local session = session_with(false)

            Recovery._fire_auto_continue(session)

            assert.equal(1, session._retry_attempt)
        end)

        it("sends nothing for a destroyed session", function()
            local session = session_with(false)
            session.destroyed = true

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(0)
        end)

        -- respawn_preserving_history clears session_id and repopulates it from
        -- an async new_session, so this window is reachable. An unprompted turn
        -- must not land on a half-respawned provider.
        it("sends nothing without a session", function()
            local session = session_with(false)
            session.session_id = nil

            Recovery._fire_auto_continue(session)

            assert.spy(submit_spy).was.called(0)
        end)

        it("is not offered when the agent does not auto-continue", function()
            local write_spy = spy.new(function() end)
            local session = session_with(false)
            session._retry_attempt = 0
            session.agent = {
                auto_continue_on_usage_limit = function()
                    return false
                end,
            }
            session.message_writer = { write_error_action = write_spy }

            Recovery.offer_auto_continue(session, os.time() + 600)

            assert.spy(write_spy).was.called(0)
            assert.equal(0, session._retry_attempt)
        end)
    end)

    describe("resolve_auth_method", function()
        local TERMINAL = { id = "term", name = "T", type = "terminal" }
        local AGENT = { id = "key", name = "K" }
        local UNKNOWN = { id = "env", name = "E", type = "env_var" }

        local cases = {
            { "arg", { TERMINAL, AGENT }, "key", nil, AGENT, nil },
            {
                "unknown arg",
                { TERMINAL, AGENT },
                "nope",
                nil,
                nil,
                "No login method 'nope'. Available: term, key.",
            },
            {
                "arg of a type this client cannot run",
                { TERMINAL, UNKNOWN },
                "env",
                nil,
                nil,
                "No login method 'env'. Available: term.",
            },
            { "preferred", { TERMINAL, AGENT }, "", "key", AGENT, nil },
            {
                "preferred not advertised",
                { TERMINAL },
                "",
                "gone",
                TERMINAL,
                nil,
            },
            { "sole runnable", { TERMINAL, UNKNOWN }, "", nil, TERMINAL, nil },
            {
                "none runnable",
                { UNKNOWN },
                "",
                nil,
                nil,
                "No login method this client can run.",
            },
            { "several", { TERMINAL, AGENT }, "", nil, nil, nil },
        }

        for _, case in ipairs(cases) do
            it(case[1], function()
                local method, problem =
                    Recovery.resolve_auth_method(case[2], case[3], case[4])

                assert.same(case[5], method)
                assert.equal(case[6], problem)
            end)
        end
    end)

    describe("login", function()
        local ACPClient = require("agentic.acp.acp_client")
        local Logger = require("agentic.utils.logger")

        local TERMINAL = {
            id = "term",
            name = "Terminal login",
            type = "terminal",
            args = { "login" },
        }
        local AGENT = { id = "key", name = "Key login", description = "A key" }

        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local system_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local respawn_stub
        --- What `authenticate` answers; overridden per case.
        --- @type agentic.acp.ACPError|nil
        local auth_err
        --- The process `vim.system` returns, recording `kill`.
        local process
        --- Ends the process, once `vim.system` has been called.
        --- @type fun(completed: table)|nil
        local exit_process

        before_each(function()
            auth_err = nil
            exit_process = nil
            process = { kill = spy.new(function() end) }
            notify_stub = spy.stub(Logger, "notify")
            system_stub = spy.stub(vim, "system")
            system_stub:invokes(function(_cmd, _opts, on_exit)
                exit_process = on_exit
                return process
            end)
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            respawn_stub = spy.stub(Recovery, "respawn_preserving_history")
            respawn_stub:invokes(function(_sm, on_created)
                on_created()
            end)
        end)

        after_each(function()
            notify_stub:revert()
            system_stub:revert()
            schedule_stub:revert()
            respawn_stub:revert()
        end)

        --- A session on an agent that advertises `methods`, recording what it
        --- writes to the chat.
        --- @param methods agentic.acp.AuthMethod[]|nil
        --- @return agentic.SessionManager session
        --- @return { actions: string[], notices: table[] } sink
        local function make_session(methods)
            local sink = { actions = {}, notices = {} }
            local session = {
                session_id = "s-1",
                destroyed = false,
                _session_epoch = 0,
                _reauth_live_retry = false,
                is_generating = false,
                agent = {
                    state = "ready",
                    auth_methods = methods,
                    provider_config = { name = "Test Agent", command = "agent" },
                    terminal_auth_invocation = ACPClient.terminal_auth_invocation,
                    authenticate = spy.new(function(_self, _id, cb)
                        cb(auth_err)
                    end),
                },
                message_writer = {
                    write_error_action = function(_self, text)
                        table.insert(sink.actions, text)
                    end,
                    write_notice = function(_self, notice)
                        table.insert(sink.notices, notice)
                    end,
                },
            } --[[@as agentic.SessionManager]]
            return session, sink
        end

        describe("login", function()
            --- @type TestStub
            local select_stub
            --- What the user picks in `vim.ui.select`; overridden per case.
            local choice

            before_each(function()
                choice = nil
                select_stub = spy.stub(vim.ui, "select")
                select_stub:invokes(function(_items, _opts, on_choice)
                    on_choice(choice)
                end)
            end)

            after_each(function()
                select_stub:revert()
            end)

            it("runs nothing before the agent is connected", function()
                local session, sink = make_session(nil)
                local on_done = spy.new(function() end)

                Recovery.login(session, "", on_done)

                assert.same(
                    { "Test Agent is not connected yet." },
                    sink.actions
                )
                assert.spy(on_done).was.called(1)
                assert.spy(system_stub).was.called(0)
            end)

            it("writes the problem with nothing to run", function()
                local session, sink = make_session({})
                local on_done = spy.new(function() end)

                Recovery.login(session, "", on_done)

                assert.same(
                    { "No login method this client can run." },
                    sink.actions
                )
                assert.spy(on_done).was.called(1)
            end)

            it("runs the chosen method when several fit", function()
                local session = make_session({ TERMINAL, AGENT })
                local on_done = spy.new(function() end)
                choice = AGENT

                Recovery.login(session, "", on_done)

                local select_opts = select_stub.calls[1][2]
                assert.equal("Key login: A key", select_opts.format_item(AGENT))
                assert.equal(
                    "Terminal login",
                    select_opts.format_item(TERMINAL)
                )
                assert.equal("key", session.agent.authenticate.calls[1][2])
                assert.spy(on_done).was.called(1)
            end)

            it("runs nothing when the choice is cancelled", function()
                local session = make_session({ TERMINAL, AGENT })
                local on_done = spy.new(function() end)

                Recovery.login(session, "", on_done)

                assert.spy(session.agent.authenticate).was.called(0)
                assert.spy(system_stub).was.called(0)
                assert.spy(on_done).was.called(1)
            end)
        end)

        describe("run_login", function()
            --- The arguments of the latest `Logger.notify`.
            --- @return table
            local function last_notice()
                return notify_stub.calls[notify_stub.call_count]
            end

            it("runs a terminal method as a process", function()
                local session = make_session({ TERMINAL })
                local on_done = spy.new(function() end)

                Recovery.run_login(session, TERMINAL, on_done)

                assert.same({ "agent", "login" }, system_stub.calls[1][1])
                assert.equal(process, session.agent.login_job)
                assert.spy(on_done).was.called(0)

                exit_process({ code = 0, signal = 0, stdout = "", stderr = "" })

                assert.spy(on_done).was.called(1)
                assert.is_nil(session.agent.login_job)
            end)

            it("finishes when the process cannot start", function()
                local session = make_session({ TERMINAL })
                local on_done = spy.new(function() end)
                system_stub:invokes(function()
                    error("ENOENT: no such file or directory")
                end)

                Recovery.run_login(session, TERMINAL, on_done)

                assert.spy(on_done).was.called(1)
                assert.is_nil(session.agent.login_job)
                assert.truthy(last_notice()[1]:find("ENOENT", 1, true))
            end)

            it("authenticates an agent method", function()
                local session = make_session({ AGENT })
                local on_done = spy.new(function() end)

                Recovery.run_login(session, AGENT, on_done)

                assert.equal("key", session.agent.authenticate.calls[1][2])
                assert.is_nil(session.agent.login_job)
                assert.spy(on_done).was.called(1)
            end)

            it("notifies the reason an agent method failed", function()
                local session = make_session({ AGENT })
                local on_done = spy.new(function() end)
                auth_err = { code = -32603, message = "denied" }

                Recovery.run_login(session, AGENT, on_done)

                assert.equal(
                    "Login with Key login failed: denied",
                    last_notice()[1]
                )
                assert.equal(vim.log.levels.WARN, last_notice()[2])
                assert.spy(on_done).was.called(1)
            end)

            local failures = {
                {
                    "the first line of stderr",
                    { code = 1, stdout = "out", stderr = "\nbad\nmore\n" },
                    "bad",
                },
                {
                    "stdout without stderr",
                    { code = 1, stdout = "out\n", stderr = "" },
                    "out",
                },
                {
                    "the exit code without output",
                    { code = 1, signal = 0, stdout = "", stderr = "" },
                    "exit 1",
                },
                -- libuv reports a process killed by a signal as exit code 0.
                {
                    "the signal that killed it",
                    { code = 0, signal = 15, stdout = "", stderr = "" },
                    "signal 15",
                },
            }
            for _, case in ipairs(failures) do
                it("notifies " .. case[1] .. " of a failed process", function()
                    local session, sink = make_session({ TERMINAL })
                    local on_done = spy.new(function() end)

                    Recovery.run_login(session, TERMINAL, on_done)
                    exit_process(case[2])

                    assert.equal(
                        "Login with Terminal login failed: " .. case[3],
                        last_notice()[1]
                    )
                    assert.equal(0, #sink.notices)
                    assert.spy(respawn_stub).was.called(0)
                    assert.spy(on_done).was.called(1)
                end)
            end

            it("stops a running login and starts the new one", function()
                local session = make_session({ TERMINAL })
                local old = { kill = spy.new(function() end) }
                session.agent.login_job = old

                Recovery.run_login(session, TERMINAL, function() end)

                assert.equal("sigterm", old.kill.calls[1][2])
                assert.spy(system_stub).was.called(1)
                assert.equal(process, session.agent.login_job)
            end)

            -- The stopped login finishes after its replacement has started.
            it("reports nothing for a stopped login", function()
                local session, sink = make_session({ TERMINAL })
                local stopped_on_done = spy.new(function() end)
                Recovery.run_login(session, TERMINAL, stopped_on_done)
                local exit_stopped = exit_process
                local replacement = { kill = spy.new(function() end) }
                process = replacement

                Recovery.run_login(session, TERMINAL, function() end)
                local notices_before = notify_stub.call_count
                exit_stopped({ code = 0, signal = 15, stdout = "", stderr = "" })

                assert.spy(stopped_on_done).was.called(1)
                assert.equal(replacement, session.agent.login_job)
                assert.equal(notices_before, notify_stub.call_count)
                assert.equal(0, #sink.notices)
            end)

            it(
                "ignores the answer to a stopped authenticate request",
                function()
                    local session, sink = make_session({ AGENT })
                    --- @type fun(err: agentic.acp.ACPError|nil)
                    local answer_stopped
                    session.agent.authenticate = function(_self, _id, cb)
                        answer_stopped = cb
                    end
                    Recovery.run_login(session, AGENT, function() end)
                    local first = answer_stopped

                    Recovery.run_login(session, AGENT, function() end)
                    local replacement = session.agent.login_job
                    first(nil)

                    assert.equal(replacement, session.agent.login_job)
                    assert.equal(0, #sink.notices)
                end
            )

            it("recovers nothing for a destroyed session", function()
                local session, sink = make_session({ AGENT })
                local on_done = spy.new(function() end)
                session.agent.authenticate = function(_self, _id, cb)
                    session.destroyed = true
                    cb(nil)
                end

                Recovery.run_login(session, AGENT, on_done)

                assert.spy(on_done).was.called(1)
                assert.equal(0, #sink.notices)
                assert.spy(respawn_stub).was.called(0)
            end)
        end)

        describe("choosing the recovery", function()
            -- A subprocess that outlived the auth failure takes the next
            -- prompt with the refreshed credentials, so nothing is replaced.
            it("keeps a ready session", function()
                local session, sink = make_session({ AGENT })

                Recovery.run_login(session, AGENT, function() end)

                assert.spy(respawn_stub).was.called(0)
                assert.equal(1, #sink.notices)
                assert.is_nil(sink.notices[1].body)
                assert.is_true(session._reauth_live_retry)
            end)

            -- The flag survives only while no turn has succeeded, so a second
            -- auth error means keeping the session did not work.
            it("respawns once the live retry is spent", function()
                local session, sink = make_session({ AGENT })
                session._reauth_live_retry = true

                Recovery.run_login(session, AGENT, function() end)

                assert.spy(respawn_stub).was.called(1)
                assert.equal(1, #sink.notices[1].body)
            end)

            it("respawns when the subprocess did not survive", function()
                local session, sink = make_session({ AGENT })
                session.agent.state = "disconnected"

                Recovery.run_login(session, AGENT, function() end)

                assert.spy(respawn_stub).was.called(1)
                assert.equal(1, #sink.notices[1].body)
            end)

            it("recovers nothing after a failed login", function()
                local session, sink = make_session({ AGENT })
                auth_err = { code = -32603, message = "denied" }

                Recovery.run_login(session, AGENT, function() end)

                assert.spy(respawn_stub).was.called(0)
                assert.equal(0, #sink.notices)
            end)

            -- An advanced epoch is `/new`, a restore, a provider switch or
            -- `/delete` landing during the login.
            it("recovers nothing into a replaced session", function()
                local session, sink = make_session({ AGENT })
                local on_done = spy.new(function() end)
                session.agent.authenticate = function(_self, _id, cb)
                    session._session_epoch = session._session_epoch + 1
                    cb(nil)
                end

                Recovery.run_login(session, AGENT, on_done)

                assert.spy(respawn_stub).was.called(0)
                assert.equal(0, #sink.notices)
                assert.spy(on_done).was.called(1)
            end)
        end)

        describe("offer_login", function()
            it("points at /login when the agent has a method", function()
                local session, sink = make_session({ TERMINAL })

                Recovery.offer_login(session)

                assert.same({ "Run /login to re-authenticate." }, sink.actions)
            end)

            it("writes nothing when the agent has none", function()
                local session, sink = make_session({})

                Recovery.offer_login(session)

                assert.same({}, sink.actions)
            end)

            it("writes nothing when the client can run none", function()
                local session, sink = make_session({
                    { id = "env", name = "E", type = "env_var" },
                })

                Recovery.offer_login(session)

                assert.same({}, sink.actions)
            end)
        end)

        describe("stop_login", function()
            it("kills a terminal method's process", function()
                local session = make_session({ TERMINAL })
                session.agent.login_job = process

                Recovery.stop_login(session)

                assert.equal("sigterm", process.kill.calls[1][2])
                assert.is_nil(session.agent.login_job)
            end)

            it("forgets an authenticate request", function()
                local session = make_session({ AGENT })
                session.agent.login_job = {}

                Recovery.stop_login(session)

                assert.is_nil(session.agent.login_job)
            end)
        end)
    end)

    describe("respawn_preserving_history", function()
        local AgentInstance = require("agentic.acp.agent_instance")
        local SessionManager = require("agentic.session_manager")

        --- @type TestStub
        local invalidate_stub
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local schedule_stub
        --- @type fun(client: table)
        local fire_ready

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            invalidate_stub = spy.stub(AgentInstance, "invalidate")
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(_name, on_ready)
                fire_ready = on_ready
            end)
        end)

        after_each(function()
            schedule_stub:revert()
            invalidate_stub:revert()
            get_instance_stub:revert()
        end)

        --- @return agentic.SessionManager
        local function make_session()
            return {
                session_id = "old",
                destroyed = false,
                chat_history = {
                    session_id = "old",
                    timestamp = 1,
                    messages = { { type = "user", text = "hi" } },
                },
                permission_manager = {
                    cancel_requests = function() end,
                },
                todo_list = { clear = function() end },
                widget = { buf_nrs = {} },
                _adopt_history = SessionManager._adopt_history,
                _sync_modified = SessionManager._sync_modified,
                _agents = {},
                _set_prompt_pending = SessionManager._set_prompt_pending,
                new_session = function(this, opts)
                    this.chat_history = {
                        session_id = "new",
                        timestamp = 2,
                        messages = {},
                    }
                    opts.on_created()
                end,
            } --[[@as agentic.SessionManager]]
        end

        it("carries the conversation into the new session", function()
            local session = make_session()
            local created = false

            Recovery.respawn_preserving_history(session, function()
                created = true
            end)
            fire_ready({ state = "ready" })

            assert.equal("new", session.chat_history.session_id)
            assert.equal(1, #session.chat_history.messages)
            assert.equal(1, #session._history_to_send)
            assert.is_true(created)
        end)

        it("creates nothing for a session destroyed meanwhile", function()
            local session = make_session()

            Recovery.respawn_preserving_history(session)
            session.destroyed = true
            fire_ready({ state = "ready" })

            assert.equal("old", session.chat_history.session_id)
            assert.is_nil(session._history_to_send)
        end)
    end)

    describe("restore_refused_prompt", function()
        local ChatWidget = require("agentic.ui.chat_widget")
        local Config = require("agentic.config")
        local MiniTest = require("mini.test")
        local original_key
        local last_owner_id = 9000
        --- @type agentic.SessionManager.PanelContext
        local NO_CONTEXT = { selections = {}, files = {}, diagnostics = {} }

        before_each(function()
            original_key = Config.keymaps.widget.switch_model
            Config.keymaps.widget.switch_model = "<M>"
        end)

        after_each(function()
            Config.keymaps.widget.switch_model = original_key
        end)

        --- A session over a real widget whose input holds `lines`, each
        --- `{ sr, er }` of `queued` tagged as a queued region, recording what
        --- goes into its context panels and chat.
        --- @param lines string[]
        --- @param queued integer[][]
        --- @return agentic.SessionManager session
        --- @return table sink
        local function make_session(lines, queued)
            local sink = {
                actions = {},
                selections = {},
                files = {},
                diagnostics = {},
            }
            last_owner_id = last_owner_id + 1
            local widget = ChatWidget:new(last_owner_id, function() end)
            MiniTest.finally(function()
                widget:destroy()
            end)
            local input = widget.buf_nrs.input
            vim.api.nvim_buf_set_lines(input, 0, -1, false, lines)
            for _, range in ipairs(queued) do
                widget:_queue_line_range(range[1], range[2])
            end
            local session = {
                widget = widget,
                code_selection = {
                    add = function(_self, selection)
                        table.insert(sink.selections, selection)
                    end,
                },
                file_list = {
                    add = function(_self, path)
                        table.insert(sink.files, path)
                    end,
                },
                diagnostics_list = {
                    add_many = function(_self, diagnostics)
                        vim.list_extend(sink.diagnostics, diagnostics)
                    end,
                },
                message_writer = {
                    write_error_action = function(_self, text)
                        table.insert(sink.actions, text)
                    end,
                },
            }
            return session, --[[@as agentic.SessionManager]]
                sink
        end

        --- @param session agentic.SessionManager
        --- @return string[]
        local function input_lines(session)
            local input = session.widget.buf_nrs.input
            return vim.api.nvim_buf_get_lines(input, 0, -1, false)
        end

        it("returns the text with its context", function()
            local session, sink = make_session({}, {})

            Recovery.restore_refused_prompt(session, "refused", {
                selections = { { lines = { "x" } } },
                files = { "/a.lua" },
                diagnostics = { { message = "d" } },
            })

            assert.same({ "refused" }, input_lines(session))
            assert.is_true(vim.bo[session.widget.buf_nrs.input].modified)
            assert.same({ { lines = { "x" } } }, sink.selections)
            assert.same({ "/a.lua" }, sink.files)
            assert.same({ { message = "d" } }, sink.diagnostics)
        end)

        it("leaves the queue as draft below the text", function()
            local session, sink = make_session(
                { "one", "", "two", "draft" },
                { { 0, 0 }, { 2, 2 } }
            )
            session._pending_bufferless_prompt = "held"

            Recovery.restore_refused_prompt(session, "refused", NO_CONTEXT)

            assert.same(
                { "refused", "", "held", "", "one", "", "two", "draft" },
                input_lines(session)
            )
            assert.equal(0, session.widget:queued_block_count())
            assert.is_nil(session._pending_bufferless_prompt)
            assert.same({
                "Prompt returned to the input. Switch model with [<M>] to send it again.",
                "3 held or queued prompt(s) left as draft.",
            }, sink.actions)
        end)

        it("puts the text in the input it is given", function()
            local session = make_session({}, {})
            local other = vim.api.nvim_create_buf(false, true)
            MiniTest.finally(function()
                vim.api.nvim_buf_delete(other, { force = true })
            end)

            Recovery.restore_refused_prompt(
                session,
                "refused",
                NO_CONTEXT,
                other
            )

            assert.same(
                { "refused" },
                vim.api.nvim_buf_get_lines(other, 0, -1, false)
            )
            assert.same({ "" }, input_lines(session))
        end)

        it("names no key when switching models has none", function()
            Config.keymaps.widget.switch_model = ""
            local session, sink = make_session({}, {})

            Recovery.restore_refused_prompt(session, "refused", NO_CONTEXT)

            assert.same({ "Prompt returned to the input." }, sink.actions)
        end)
    end)
end)
