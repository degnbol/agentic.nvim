--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch
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
    end)

    describe("re-authentication", function()
        local AgentInstance = require("agentic.acp.agent_instance")
        local Logger = require("agentic.utils.logger")
        local SessionManager = require("agentic.session_manager")

        --- @type TestStub
        local system_stub
        --- @type TestStub
        local schedule_stub
        --- @type TestStub
        local notify_stub
        --- Exit code `claude auth login` reports; overridden per case.
        local exit_code

        before_each(function()
            exit_code = 0
            system_stub = spy.stub(vim, "system")
            system_stub:invokes(function(_cmd, _opts, cb)
                cb({ code = exit_code })
            end)
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            system_stub:revert()
            schedule_stub:revert()
            notify_stub:revert()
        end)

        describe("choosing the recovery", function()
            --- @type TestStub
            local respawn_stub
            --- @type table[]
            local notices

            before_each(function()
                notices = {}
                respawn_stub = spy.stub(Recovery, "respawn_preserving_history")
                respawn_stub:invokes(function(_sm, on_created)
                    on_created()
                end)
            end)

            after_each(function()
                respawn_stub:revert()
            end)

            --- @return agentic.SessionManager
            local function make_session()
                return {
                    session_id = "s-1",
                    destroyed = false,
                    _session_epoch = 0,
                    _reauth_live_retry = false,
                    is_generating = false,
                    agent = { state = "ready" },
                    message_writer = {
                        write_notice = function(_self, notice)
                            table.insert(notices, notice)
                        end,
                    },
                } --[[@as agentic.SessionManager]]
            end

            -- A subprocess that outlived the auth failure takes the next
            -- prompt with the refreshed credentials, so nothing is replaced.
            it("keeps a ready session", function()
                local session = make_session()

                Recovery.run_reauth(session)

                assert.spy(respawn_stub).was.called(0)
                assert.equal(1, #notices)
                assert.is_nil(notices[1].body)
                assert.is_true(session._reauth_live_retry)
            end)

            -- The flag survives only while no turn has succeeded, so a second
            -- auth error means keeping the session did not work.
            it("respawns once the live retry is spent", function()
                local session = make_session()
                session._reauth_live_retry = true

                Recovery.run_reauth(session)

                assert.spy(respawn_stub).was.called(1)
                assert.equal(1, #notices[1].body)
            end)

            it("respawns when the subprocess did not survive", function()
                local session = make_session()
                session.agent.state = "disconnected"

                Recovery.run_reauth(session)

                assert.spy(respawn_stub).was.called(1)
                assert.equal(1, #notices[1].body)
            end)

            it("recovers nothing after a failed login", function()
                local session = make_session()
                exit_code = 1

                Recovery.run_reauth(session)

                assert.spy(respawn_stub).was.called(0)
                assert.equal(0, #notices)
                assert.spy(notify_stub).was.called(2)
            end)

            -- An advanced epoch is `/new`, a restore, a provider switch or
            -- `/delete` landing during the OAuth round-trip.
            it("recovers nothing into a replaced session", function()
                local session = make_session()
                system_stub:invokes(function(_cmd, _opts, cb)
                    session._session_epoch = session._session_epoch + 1
                    cb({ code = 0 })
                end)

                Recovery.run_reauth(session)

                assert.spy(respawn_stub).was.called(0)
                assert.equal(0, #notices)
            end)

            it("does not spawn a second login", function()
                local session = make_session()
                session._reauth_job = {}

                Recovery.run_reauth(session)

                assert.spy(system_stub).was.called(0)
            end)
        end)

        describe("respawn_preserving_history", function()
            --- @type TestStub
            local invalidate_stub
            --- @type TestStub
            local get_instance_stub
            --- @type fun(client: table)
            local fire_ready

            before_each(function()
                invalidate_stub = spy.stub(AgentInstance, "invalidate")
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_name, on_ready)
                    fire_ready = on_ready
                end)
            end)

            after_each(function()
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
            return session --[[@as agentic.SessionManager]], sink
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
            local session, sink =
                make_session({ "one", "", "two", "draft" }, { { 0, 0 }, { 2, 2 } })
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

            Recovery.restore_refused_prompt(session, "refused", NO_CONTEXT, other)

            assert.same({ "refused" }, vim.api.nvim_buf_get_lines(other, 0, -1, false))
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
