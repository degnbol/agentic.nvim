--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, need-check-nil, undefined-field, param-type-mismatch, return-type-mismatch
local assert = require("tests.helpers.assert")
local Deferred = require("tests.helpers.deferred")
local spy = require("tests.helpers.spy")

local Recovery = require("agentic.session_recovery")
local SessionManager = require("agentic.session_manager")

describe("agentic.session_recovery", function()
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
        local restart_stub
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
            restart_stub = spy.stub(Recovery, "restart_client")
            restart_stub:invokes(function(_sm, on_created)
                on_created()
            end)
        end)

        after_each(function()
            notify_stub:revert()
            system_stub:revert()
            schedule_stub:revert()
            restart_stub:revert()
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
                _prompt_pending = 0,
                _replaying = SessionManager._replaying,
                _turn_open = SessionManager._turn_open,
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
                    assert.spy(restart_stub).was.called(0)
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
                assert.spy(restart_stub).was.called(0)
            end)
        end)

        describe("choosing the recovery", function()
            -- A subprocess that outlived the auth failure takes the next
            -- prompt with the refreshed credentials, so nothing is replaced.
            it("keeps a ready session", function()
                local session, sink = make_session({ AGENT })

                Recovery.run_login(session, AGENT, function() end)

                assert.spy(restart_stub).was.called(0)
                assert.equal(1, #sink.notices)
                assert.is_nil(sink.notices[1].body)
                assert.is_true(session._reauth_live_retry)
            end)

            -- The flag survives only while no turn has succeeded, so a second
            -- auth error means keeping the session did not work.
            it("restarts the client once the live retry is spent", function()
                local session, sink = make_session({ AGENT })
                session._reauth_live_retry = true

                Recovery.run_login(session, AGENT, function() end)

                assert.spy(restart_stub).was.called(1)
                assert.equal(1, #sink.notices[1].body)
            end)

            it(
                "restarts the client when the subprocess did not survive",
                function()
                    local session, sink = make_session({ AGENT })
                    session.agent.state = "disconnected"

                    Recovery.run_login(session, AGENT, function() end)

                    assert.spy(restart_stub).was.called(1)
                    assert.equal(1, #sink.notices[1].body)
                end
            )

            it("recovers nothing after a failed login", function()
                local session, sink = make_session({ AGENT })
                auth_err = { code = -32603, message = "denied" }

                Recovery.run_login(session, AGENT, function() end)

                assert.spy(restart_stub).was.called(0)
                assert.equal(0, #sink.notices)
            end)

            -- An advanced epoch is `/new`, a resume, a provider switch or
            -- `/delete` landing during the login.
            it("recovers nothing into a replaced session", function()
                local session, sink = make_session({ AGENT })
                local on_done = spy.new(function() end)
                session.agent.authenticate = function(_self, _id, cb)
                    session._session_epoch = session._session_epoch + 1
                    cb(nil)
                end

                Recovery.run_login(session, AGENT, on_done)

                assert.spy(restart_stub).was.called(0)
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

    describe("session renewal", function()
        local SessionRegistry = require("agentic.session_registry")

        --- @type tests.helpers.Deferred
        local deferred
        --- @type table<integer, agentic.SessionManager>
        local original_sessions
        --- `on_closed` of each `close_session`, by session id.
        --- @type table<string, fun()>
        local close_answers
        --- `on_ready` of the last `restart`.
        --- @type fun(client: table)|nil
        local fire_ready
        --- A shared client, recording what each session held when `restart`
        --- ran.
        local client
        --- Each session's `session_id` and permission cancels at `restart`.
        --- @type table<agentic.SessionManager, { session_id: string|nil, cancels: integer }>
        local at_restart

        before_each(function()
            deferred = Deferred.capture()
            original_sessions = SessionRegistry.by_id
            SessionRegistry.by_id = {}
            close_answers = {}
            fire_ready = nil
            at_restart = {}
            client = {
                state = "ready",
                stop = spy.new(function() end),
                close_session = spy.new(function(_self, session_id, on_closed)
                    close_answers[session_id] = on_closed
                end),
                restart = spy.new(function(self, on_ready)
                    for _, session in pairs(SessionRegistry.by_id) do
                        at_restart[session] = {
                            session_id = session.session_id,
                            cancels = session.permission_manager.cancel_requests.call_count,
                        }
                    end
                    self.state = "initializing"
                    fire_ready = on_ready
                end),
            }
        end)

        after_each(function()
            deferred.revert()
            SessionRegistry.by_id = original_sessions
        end)

        --- A registered session on `agent` holding ACP session `session_id`.
        --- @param id integer `SessionManager.id`
        --- @param session_id string|nil
        --- @param agent table|nil Default the shared client
        --- @return agentic.SessionManager
        local function make_session(id, session_id, agent)
            local session = {
                id = id,
                session_id = session_id,
                destroyed = false,
                _session_epoch = 0,
                agent = agent or client,
                chat_history = {
                    session_id = session_id,
                    timestamp = 1,
                    messages = { { type = "user", text = "hi" } },
                },
                permission_manager = {
                    cancel_requests = spy.new(function() end),
                },
                todo_list = { clear = function() end },
                config_options = {
                    current_model_id = function()
                        return "live"
                    end,
                },
                _reapply_model = function() end,
                new_session = spy.new(function(self, opts)
                    self._session_epoch = self._session_epoch + 1
                    if opts.on_created then
                        opts.on_created()
                    end
                end),
            } --[[@as agentic.SessionManager]]
            SessionRegistry.by_id[id] = session
            return session
        end

        describe("renew_session", function()
            it("reapplies the model that ran before the renewal", function()
                local session = make_session(1, "old")
                local order = {}
                session._reapply_model = function(_, model_id)
                    table.insert(order, "reapply " .. model_id)
                end

                Recovery.renew_session(session, function()
                    table.insert(order, "on_created")
                end)
                -- The new session's options hold no model yet when it is created.
                session.config_options.current_model_id = function() end
                close_answers.old()

                assert.same({ "reapply live", "on_created" }, order)
            end)

            it("creates the new session after the old one closes", function()
                local session = make_session(1, "old")
                local history = session.chat_history
                local created = spy.new(function() end)

                Recovery.renew_session(session, created)

                assert.equal(client, session.agent)
                assert.is_nil(session.session_id)
                assert
                    .spy(session.permission_manager.cancel_requests).was
                    .called(1)
                assert.equal("old", client.close_session.calls[1][2])
                assert.spy(session.new_session).was.called(0)

                close_answers.old()

                local opts = session.new_session.calls[1][2]
                assert.equal(history, opts.history)
                assert.is_true(opts.quiet_welcome)
                assert.spy(created).was.called(1)
            end)

            it("creates nothing for a session destroyed meanwhile", function()
                local session = make_session(1, "old")

                Recovery.renew_session(session)
                session.destroyed = true
                close_answers.old()

                assert.spy(session.new_session).was.called(0)
            end)

            it("creates nothing for a session that moved on", function()
                local session = make_session(1, "old")

                Recovery.renew_session(session)
                session._session_epoch = session._session_epoch + 1
                close_answers.old()

                assert.spy(session.new_session).was.called(0)
            end)

            it("creates at once without a session id", function()
                local session = make_session(1, nil)

                Recovery.renew_session(session)

                assert.spy(client.close_session).was.called(0)
                assert.spy(session.new_session).was.called(1)
            end)

            it("leaves the shared client running", function()
                local session = make_session(1, "old")
                local sibling = make_session(2, "other")

                Recovery.renew_session(session)
                close_answers.old()

                assert.spy(client.stop).was.called(0)
                assert.spy(client.restart).was.called(0)
                assert.equal(client, sibling.agent)
                assert.equal("other", sibling.session_id)
            end)
        end)

        describe("restart_client", function()
            it("renews every live session on the client", function()
                local session = make_session(1, "a")
                local sibling = make_session(2, "b")
                local pending = make_session(3, nil)
                local moved = make_session(4, "d")
                local elsewhere = make_session(5, "e", { state = "ready" })
                local created = spy.new(function() end)

                Recovery.restart_client(session, created)

                -- Prompts are answered while the old subprocess still runs.
                assert.spy(client.restart).was.called(1)
                for _, held in ipairs({ session, sibling, pending, moved }) do
                    assert.same(
                        { session_id = nil, cancels = 1 },
                        at_restart[held]
                    )
                end
                assert.equal("e", elsewhere.session_id)
                assert
                    .spy(elsewhere.permission_manager.cancel_requests).was
                    .called(0)

                moved._session_epoch = moved._session_epoch + 1
                fire_ready(client)
                deferred.drain()

                assert.spy(client.close_session).was.called(0)
                for _, renewed in ipairs({ session, sibling, pending }) do
                    assert.spy(renewed.new_session).was.called(1)
                end
                assert.spy(moved.new_session).was.called(0)
                assert.spy(elsewhere.new_session).was.called(0)
                assert.spy(created).was.called(1)
            end)

            it("renews no session destroyed during the restart", function()
                local session = make_session(1, "a")
                local sibling = make_session(2, "b")

                Recovery.restart_client(session)
                sibling.destroyed = true
                fire_ready(client)
                deferred.drain()

                assert.spy(session.new_session).was.called(1)
                assert.spy(sibling.new_session).was.called(0)
            end)
        end)
    end)

    describe("prompts put back in the input", function()
        local ChatWidget = require("agentic.ui.chat_widget")
        local UsageLimit = require("agentic.acp.usage_limit")
        local Config = require("agentic.config")
        local MiniTest = require("mini.test")
        local original_key
        local original_fork_key
        local last_owner_id = 9000
        --- @type agentic.SessionManager.PanelContext
        local NO_CONTEXT = { selections = {}, files = {}, diagnostics = {} }
        local FORK_ACTION =
            "The refused prompt stays in this session. Fork before it with [<F>] on its turn."

        before_each(function()
            original_key = Config.keymaps.widget.switch_model
            original_fork_key = Config.keymaps.agent.fork
            Config.keymaps.widget.switch_model = "<M>"
            Config.keymaps.agent.fork = { { "<F>", mode = "n" }, "<G>" }
        end)

        after_each(function()
            Config.keymaps.widget.switch_model = original_key
            Config.keymaps.agent.fork = original_fork_key
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
                widget.input_dispatch:_queue_line_range(range[1], range[2])
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
                agent = {
                    auto_continue_on_usage_limit = function()
                        return sink.auto_continue ~= false
                    end,
                },
                _queue_input = SessionManager._queue_input,
                _withdraw_auto_continue = SessionManager._withdraw_auto_continue,
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

        --- Queued regions of the session's input as `{ start_row, end_row }`
        --- pairs in buffer order.
        --- @param session agentic.SessionManager
        --- @return integer[][]
        local function tags(session)
            local ns = vim.api.nvim_create_namespace("agentic_queued_region")
            local marks = vim.api.nvim_buf_get_extmarks(
                session.widget.buf_nrs.input,
                ns,
                0,
                -1,
                { details = true }
            )
            return vim.tbl_map(function(m)
                return { m[2], m[4].end_row }
            end, marks)
        end

        describe("requeue_limited_prompt", function()
            it(
                "puts the text above the queue, tagged, with its context",
                function()
                    local session, sink = make_session(
                        { "draft", "", "queued" },
                        { { 2, 2 } }
                    )

                    Recovery.requeue_limited_prompt(session, "limited", {
                        selections = {},
                        files = { "/a.lua" },
                        diagnostics = {},
                    })

                    assert.same(
                        { "draft", "", "limited", "", "queued" },
                        input_lines(session)
                    )
                    assert.same({ { 2, 2 }, { 4, 4 } }, tags(session))
                    assert.same({ "/a.lua" }, sink.files)
                    assert.same({}, sink.actions)
                end
            )

            it("leaves no room for an automatic continue", function()
                local session = make_session({}, {})
                local limit = UsageLimit:new(function() end)
                limit.lifts_at = os.time() + 600

                Recovery.requeue_limited_prompt(session, "limited", NO_CONTEXT)
                Recovery.offer_auto_continue(session, limit)

                assert.same({ "limited" }, input_lines(session))
                assert.is_nil(session._continue_mark)
            end)
        end)

        describe("return_limited_prompt", function()
            it("drafts the text on top, keeping the queue tagged", function()
                local session, sink = make_session({ "queued" }, { { 0, 0 } })

                Recovery.return_limited_prompt(session, "limited", {
                    selections = {},
                    files = { "/a.lua" },
                    diagnostics = {},
                })

                assert.same({ "limited", "", "queued" }, input_lines(session))
                assert.same({ { 2, 2 } }, tags(session))
                assert.same({ "/a.lua" }, sink.files)
                assert.same({}, sink.actions)
            end)
        end)

        describe("offer_auto_continue", function()
            --- @param attempt integer
            --- @return agentic.acp.UsageLimit
            local function limit_at(attempt)
                local limit = UsageLimit:new(function() end)
                limit.attempt = attempt
                -- Reads as 10m through a second boundary.
                limit.lifts_at = os.time() + 630
                return limit
            end

            it(
                "queues continue in a blank input and says when it sends",
                function()
                    local session, sink = make_session({}, {})

                    Recovery.offer_auto_continue(session, limit_at(1))

                    assert.same({ "continue" }, input_lines(session))
                    assert.same({ { 0, 0 } }, tags(session))
                    assert.is_not_nil(session._continue_mark)
                    assert.same(
                        { "Usage limit: queued prompts send in 10m." },
                        sink.actions
                    )
                end
            )

            it("names a repeat attempt", function()
                local session, sink = make_session({}, {})

                Recovery.offer_auto_continue(session, limit_at(2))

                assert.same({
                    "Usage limit: queued prompts send in 10m (attempt 2/3).",
                }, sink.actions)
            end)

            it("queues nothing with draft or queued text", function()
                for _, setup in ipairs({
                    { { "draft" }, {} },
                    { { "queued" }, { { 0, 0 } } },
                }) do
                    local session = make_session(setup[1], setup[2])

                    Recovery.offer_auto_continue(session, limit_at(1))

                    assert.same(setup[1], input_lines(session))
                    assert.is_nil(session._continue_mark)
                end
            end)

            it("queues nothing while the input is typed in", function()
                local session = make_session({}, {})
                local input = session.widget.buf_nrs.input
                local in_insert = spy.stub(
                    require("agentic.utils.buf_helpers"),
                    "in_insert_mode"
                )
                in_insert:returns(true)
                local current = spy.stub(vim.api, "nvim_get_current_buf")
                current:returns(input)
                MiniTest.finally(function()
                    in_insert:revert()
                    current:revert()
                end)

                Recovery.offer_auto_continue(session, limit_at(1))

                assert.is_nil(session._continue_mark)
            end)

            it("queues nothing, with no attempt count, when off", function()
                local session, sink = make_session({}, {})
                sink.auto_continue = false

                Recovery.offer_auto_continue(session, limit_at(2))

                assert.same({ "" }, input_lines(session))
                assert.same(
                    { "Usage limit: queued prompts send in 10m." },
                    sink.actions
                )
            end)

            it("gives up after MAX_ATTEMPTS", function()
                local session, sink = make_session({}, {})

                Recovery.offer_auto_continue(
                    session,
                    limit_at(UsageLimit.MAX_ATTEMPTS + 1)
                )

                assert.same({ "" }, input_lines(session))
                assert.equal(
                    "Auto-continue gave up after 3 attempts.",
                    sink.actions[2]
                )
            end)

            -- The automatic "continue" drains as a prompt; the limit can
            -- turn it away again.
            it("withdraws a turned-away continue on giving up", function()
                local session = make_session({ "mine" }, { { 0, 0 } })
                session._continue_mark = 1
                Recovery.requeue_limited_prompt(session, "continue", NO_CONTEXT)
                assert.same({ "continue", "", "mine" }, input_lines(session))

                Recovery.offer_auto_continue(
                    session,
                    limit_at(UsageLimit.MAX_ATTEMPTS + 1)
                )

                assert.same({ "mine" }, input_lines(session))
                assert.is_nil(session._continue_mark)
            end)

            it("keeps focus and mode", function()
                local session = make_session({}, {})
                local win = vim.api.nvim_get_current_win()
                local mode = vim.api.nvim_get_mode().mode

                Recovery.offer_auto_continue(session, limit_at(1))

                assert.equal(win, vim.api.nvim_get_current_win())
                assert.equal(mode, vim.api.nvim_get_mode().mode)
            end)
        end)

        describe("restore_refused_prompt", function()
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
                session._continue_mark = 1

                Recovery.restore_refused_prompt(session, "refused", NO_CONTEXT)

                assert.same(
                    { "refused", "", "one", "", "two", "draft" },
                    input_lines(session)
                )
                assert.equal(
                    0,
                    session.widget.input_dispatch:queued_block_count()
                )
                assert.is_nil(session._continue_mark)
                assert.same({
                    "Prompt returned to the input. Switch model with [<M>] to send it again.",
                    FORK_ACTION,
                    "2 queued prompt(s) left as draft.",
                }, sink.actions)
            end)

            it("counts a held bufferless prompt as queued", function()
                local session, sink = make_session({}, {})
                session:_queue_input("held")

                Recovery.restore_refused_prompt(session, "refused", NO_CONTEXT)

                assert.same({ "refused", "", "held" }, input_lines(session))
                assert.equal(
                    "1 queued prompt(s) left as draft.",
                    sink.actions[3]
                )
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

                assert.same(
                    { "Prompt returned to the input.", FORK_ACTION },
                    sink.actions
                )
            end)

            it("names no fork key when forking has none", function()
                Config.keymaps.agent.fork = ""
                local session, sink = make_session({}, {})

                Recovery.restore_refused_prompt(session, "refused", NO_CONTEXT)

                assert.same({
                    "Prompt returned to the input. Switch model with [<M>] to send it again.",
                }, sink.actions)
            end)
        end)
    end)
end)
