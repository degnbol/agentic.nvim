--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, need-check-nil
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local BackgroundSession = require("agentic.background_session")
local ChatHistory = require("agentic.ui.chat_history")
local Claims = require("agentic.skeptic.claims")
local Config = require("agentic.config")
local deferred_helper = require("tests.helpers.deferred")
local Listeners = require("agentic.utils.listeners")
local Logger = require("agentic.utils.logger")
local MiniTest = require("mini.test")
local SessionManager = require("agentic.session_manager")
local SessionRegistry = require("agentic.session_registry")
local Skeptic = require("agentic.skeptic").Skeptic
local TextModel = require("agentic.utils.text_model")

--- A fake main session: real event lists, a history, and a `send_from`
--- that records each prompt and adds its row unless `held_cause` is set.
--- @return table session
local function fake_session()
    local listeners = {
        turn_end = Listeners:new(),
        session_changed = Listeners:new(),
        destroy = Listeners:new(),
    }
    local session = {
        extensions = {},
        chat_history = ChatHistory:new(),
        widget = {},
        agent = {
            claude_config_dir = function()
                return "/cfg"
            end,
        },
        sent = {},
        held_cause = nil,
    }
    function session:on(event, listener)
        return listeners[event]:add(listener)
    end
    function session:emit(event, data)
        listeners[event]:call(self, data)
    end
    function session:cwd()
        return "/project"
    end
    function session:send_from(author, text)
        table.insert(self.sent, { author = author, text = text })
        if self.held_cause then
            return self.held_cause
        end
        self.chat_history:add_message({
            type = "user",
            text = text,
            timestamp = 0,
            provider_name = "p",
            author = author,
        })
        return nil
    end
    return session
end

--- Add a user prompt row to `session`'s history.
--- @param session table
--- @param text string
--- @return agentic.ui.ChatHistory.UserMessage
local function add_prompt(session, text)
    --- @type agentic.ui.ChatHistory.UserMessage
    local msg =
        { type = "user", text = text, timestamp = 0, provider_name = "p" }
    session.chat_history:add_message(msg)
    return msg
end

--- @param session table
--- @param text string
local function add_reply(session, text)
    session.chat_history:add_message({
        type = "agent",
        text = text,
        provider_name = "p",
    })
end

--- @param claim integer
--- @param word string
--- @return string reply A skeptic reply with one verdict
local function reply(claim, word)
    return ('```json\n[{"claim": %d, "verdict": "%s", "evidence": "e%d"}]\n```'):format(
        claim,
        word,
        claim
    )
end

describe("agentic.skeptic.Skeptic", function()
    --- @type TestStub
    local available_stub
    --- @type TestStub
    local extract_stub
    --- @type TestStub
    local background_stub
    --- @type TestStub
    local notify_stub
    --- Each `Claims.extract` call: its turn, checked claims and callback.
    --- @type { turn: agentic.skeptic.Turn, checked: string[], on_done: function }[]
    local extracts
    --- Each fake skeptic agent, with the prompts it got.
    --- @type table[]
    local agents

    before_each(function()
        extracts = {}
        agents = {}
        available_stub = spy.stub(TextModel, "available")
        available_stub:returns(true)
        extract_stub = spy.stub(Claims, "extract")
        extract_stub:invokes(function(turn, checked, on_done)
            table.insert(extracts, {
                turn = turn,
                checked = vim.deepcopy(checked),
                on_done = on_done,
            })
        end)
        background_stub = spy.stub(BackgroundSession, "new")
        background_stub:invokes(function(_self, opts)
            local agent = { opts = opts, prompts = {}, destroyed = false }
            function agent:prompt(text, on_done)
                table.insert(self.prompts, { text = text, on_done = on_done })
            end
            function agent:destroy()
                self.destroyed = true
                for _, p in ipairs(self.prompts) do
                    p.on_done(nil, "closed")
                end
                opts.on_destroy(nil, true)
            end
            --- End the session by itself with `err`, as one that was
            --- `ready` or not.
            function agent:fail(err, ready)
                self.destroyed = true
                opts.on_destroy(err, ready)
            end
            table.insert(agents, agent)
            return agent
        end)
        notify_stub = spy.stub(Logger, "notify")
    end)

    after_each(function()
        available_stub:revert()
        extract_stub:revert()
        background_stub:revert()
        notify_stub:revert()
    end)

    --- An enabled skeptic on a fresh fake session.
    --- @return agentic.skeptic.Skeptic skeptic
    --- @return table session
    local function enabled_skeptic()
        local session = fake_session()
        local skeptic = Skeptic:new(session)
        skeptic:enable()
        return skeptic, session
    end

    --- End a turn of `session` normally, on `user_msg`.
    --- @param session table
    --- @param user_msg agentic.ui.ChatHistory.UserMessage|nil
    --- @param stop_reason string|nil Default `end_turn`
    local function end_turn(session, user_msg, stop_reason)
        session:emit("turn_end", {
            user_msg = user_msg,
            stop_reason = stop_reason or "end_turn",
        })
    end

    --- Answer every skeptic's last prompt with `replies[i]`.
    --- @param replies string[]
    local function answer(replies)
        for i, agent in ipairs(agents) do
            local p = agent.prompts[#agent.prompts]
            p.on_done(replies[i], nil)
        end
    end

    it("attaches itself to the session", function()
        local session = fake_session()
        local skeptic = Skeptic:new(session)

        assert.equal(skeptic, session.extensions.skeptic)
    end)

    it("starts one agent per configured skeptic", function()
        enabled_skeptic()

        assert.equal(#Config.skeptic.skeptics, #agents)
        assert.equal("/project", agents[1].opts.cwd)
        assert.equal("skeptic glm-5.3", agents[1].opts.label)
        assert.equal("/cfg", agents[1].opts.get_config_dir())
    end)

    it("stays off without a text model", function()
        available_stub:returns(false)
        local skeptic = Skeptic:new(fake_session())

        skeptic:enable()

        assert.equal(0, #agents)
        assert.is_false(skeptic._enabled)
        assert.equal(1, notify_stub.call_count)
    end)

    it("checks nothing while off", function()
        local session = fake_session()
        Skeptic:new(session)
        local msg = add_prompt(session, "go")

        end_turn(session, msg)

        assert.equal(0, #extracts)
    end)

    it("forwards a claim every skeptic refutes", function()
        local _, session = enabled_skeptic()
        local msg = add_prompt(session, "fix x")
        add_reply(session, "x is fixed; y is 1")

        end_turn(session, msg)
        assert.same({ "fix x" }, extracts[1].turn.prompts)
        extracts[1].on_done({ "x is fixed", "y is 1" }, nil)

        assert.truthy(
            agents[1].prompts[1].text:find(
                "1. x is fixed\n\n2. y is 1",
                1,
                true
            )
        )
        answer({
            reply(1, "refuted") .. "\n",
            '```json\n[{"claim": 1, "verdict": "refuted", "evidence": "f1"},'
                .. ' {"claim": 2, "verdict": "refuted", "evidence": "f2"}]\n```',
        })

        assert.equal(1, #session.sent)
        assert.equal("skeptic", session.sent[1].author)
        local text = session.sent[1].text
        assert.truthy(text:find("^Background skeptics"))
        assert.truthy(text:find("1. x is fixed\n   - e1\n   - f1", 1, true))
        assert.is_nil(text:find("y is 1", 1, true))
    end)

    it("sends nothing when no claim meets the reporting criteria", function()
        local _, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "go"))
        extracts[1].on_done({ "a" }, nil)

        answer({ reply(1, "refuted"), reply(1, "supported") })

        assert.equal(0, #session.sent)
    end)

    it("stops at an extraction with no claims", function()
        local _, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "go"))

        extracts[1].on_done({}, nil)

        assert.equal(0, #agents[1].prompts)
    end)

    it("leaves out claims checked earlier", function()
        local _, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "one"))
        extracts[1].on_done({ "a" }, nil)
        answer({ reply(1, "supported"), reply(1, "supported") })

        end_turn(session, add_prompt(session, "two"))

        assert.same({ "a" }, extracts[2].checked)
        assert.same({ "two" }, extracts[2].turn.prompts)
    end)

    -- One round: the turn answering the skeptic is not checked, and its
    -- content does not reach the next check either.
    it("collects its own turn without checking it", function()
        local _, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "go"))
        extracts[1].on_done({ "a" }, nil)
        answer({ reply(1, "refuted"), reply(1, "refuted") })
        local own =
            session.chat_history.messages[#session.chat_history.messages]
        add_reply(session, "checked again, a holds")

        end_turn(session, own)
        assert.equal(1, #extracts)

        end_turn(session, add_prompt(session, "next"))
        assert.equal(2, #extracts)
        assert.equal("", extracts[2].turn.text)
    end)

    it("carries a prompt sent during its own turn to the next check", function()
        local _, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "go"))
        extracts[1].on_done({ "a" }, nil)
        answer({ reply(1, "refuted"), reply(1, "refuted") })
        local own =
            session.chat_history.messages[#session.chat_history.messages]
        local queued = add_prompt(session, "meanwhile")
        add_reply(session, "a holds after all")

        end_turn(session, own)
        add_reply(session, "done meanwhile")
        end_turn(session, queued)

        assert.equal(2, #extracts)
        assert.same({ "meanwhile" }, extracts[2].turn.prompts)
        assert.equal("done meanwhile", extracts[2].turn.text)
    end)

    it(
        "counts a claim as checked only once a skeptic gave a verdict",
        function()
            local _, session = enabled_skeptic()
            end_turn(session, add_prompt(session, "one"))
            extracts[1].on_done({ "a", "b" }, nil)
            answer({ reply(2, "supported"), "no verdicts here" })

            end_turn(session, add_prompt(session, "two"))

            assert.same({ "b" }, extracts[2].checked)
        end
    )

    it("starts at the next prompt after off and on", function()
        local skeptic, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "one"))
        extracts[1].on_done({}, nil)
        skeptic:disable()
        end_turn(session, add_prompt(session, "while off"))

        skeptic:enable()
        end_turn(session, add_prompt(session, "back on"))

        assert.same({ "back on" }, extracts[2].turn.prompts)
    end)

    it("defers a stopped or failed turn to the next normal one", function()
        local _, session = enabled_skeptic()
        local first = add_prompt(session, "first")
        add_reply(session, "partial")

        end_turn(session, first, "cancelled")
        session:emit("turn_end", { user_msg = first, stop_reason = nil })
        assert.equal(0, #extracts)

        end_turn(session, add_prompt(session, "second"))
        assert.same({ "first", "second" }, extracts[1].turn.prompts)
        assert.equal("partial", extracts[1].turn.text)
    end)

    it("merges turns that end while a check runs into the next", function()
        local _, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "one"))
        end_turn(session, add_prompt(session, "two"))
        end_turn(session, add_prompt(session, "three"))
        assert.equal(1, #extracts)

        extracts[1].on_done({}, nil)

        assert.equal(2, #extracts)
        assert.same({ "two", "three" }, extracts[2].turn.prompts)
    end)

    it("reports a failed extraction and goes on", function()
        local _, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "one"))
        end_turn(session, add_prompt(session, "two"))

        extracts[1].on_done(nil, "timeout")

        assert.equal(1, notify_stub.call_count)
        assert.equal(2, #extracts)
    end)

    it("keeps a held delivery for the next normal turn end", function()
        local _, session = enabled_skeptic()
        session.held_cause = "the session is still loading"
        end_turn(session, add_prompt(session, "go"))
        extracts[1].on_done({ "a" }, nil)
        answer({ reply(1, "refuted"), reply(1, "refuted") })
        assert.equal(1, #session.sent)

        session.held_cause = nil
        end_turn(session, add_prompt(session, "next"), "cancelled")
        assert.equal(1, #session.sent)
        end_turn(session, add_prompt(session, "again"))

        assert.equal(2, #session.sent)
        assert.equal(session.sent[1].text, session.sent[2].text)
    end)

    it("drops a running check on disable", function()
        local skeptic, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "go"))
        extracts[1].on_done({ "a" }, nil)
        local first_agents = agents

        skeptic:disable()

        assert.is_true(first_agents[1].destroyed)
        assert.is_true(first_agents[2].destroyed)
        assert.equal(0, #session.sent)
        assert.equal(0, notify_stub.call_count)
        assert.is_false(skeptic._running)
    end)

    it("drops a late extraction after disable", function()
        local skeptic, session = enabled_skeptic()
        end_turn(session, add_prompt(session, "go"))

        skeptic:disable()
        extracts[1].on_done({ "a" }, nil)

        assert.equal(0, #agents[1].prompts)
    end)

    it("is disabled when the session is destroyed", function()
        local skeptic, session = enabled_skeptic()

        session:emit("destroy", {})

        assert.is_false(skeptic._enabled)
        assert.is_true(agents[1].destroyed)
        -- Unsubscribed: a later turn end reaches no skeptic.
        skeptic._enabled = true
        end_turn(session, add_prompt(session, "go"))
        assert.equal(0, #extracts)
    end)

    describe("an agent that stops", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = deferred_helper.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        it("is started again with the same spec", function()
            local skeptic = enabled_skeptic()
            local stopped = agents[1]

            stopped:fail("disconnected", true)
            deferred.drain()

            assert.equal(3, #agents)
            assert.equal(stopped.opts.model, agents[3].opts.model)
            assert.same(
                { agents[2], agents[3] },
                vim.tbl_map(function(agent)
                    return agent.session
                end, skeptic._agents)
            )
        end)

        it("is dropped when closed, as by a wiped transcript", function()
            local skeptic = enabled_skeptic()

            agents[1]:destroy()
            deferred.drain()

            assert.equal(2, #agents)
            assert.same(
                { agents[2] },
                vim.tbl_map(function(agent)
                    return agent.session
                end, skeptic._agents)
            )
            assert.is_true(skeptic._enabled)
        end)

        it("is not started again after off", function()
            local skeptic = enabled_skeptic()

            skeptic:disable()
            deferred.drain()

            assert.equal(2, #agents)
            assert.equal(0, #skeptic._agents)
        end)

        it("is dropped, with a notify, when it failed to start", function()
            local skeptic = enabled_skeptic()

            agents[1]:fail("unknown model", false)
            deferred.drain()

            assert.equal(2, #agents)
            assert.same(
                { agents[2] },
                vim.tbl_map(function(agent)
                    return agent.session
                end, skeptic._agents)
            )
            assert.truthy(
                notify_stub.calls[1][1]:find("unknown model", 1, true)
            )
            assert.is_true(skeptic._enabled)
        end)

        it("turns the skeptic off when every agent failed to start", function()
            local skeptic = enabled_skeptic()

            agents[1]:fail("timeout", false)
            agents[2]:fail("timeout", false)
            deferred.drain()

            assert.is_false(skeptic._enabled)
            assert.equal(3, notify_stub.call_count)
        end)

        it("turns the skeptic off when none can start again", function()
            local skeptic = enabled_skeptic()
            background_stub:returns(nil)

            agents[1]:fail("disconnected", true)
            agents[2]:fail("disconnected", true)
            deferred.drain()

            assert.is_false(skeptic._enabled)
            assert.equal(1, notify_stub.call_count)
        end)
    end)

    describe("session_changed", function()
        --- A skeptic whose session checked claim `a`, then changed to a
        --- history of an old exchange and a new prompt.
        --- @param continued boolean
        --- @return table session
        --- @return agentic.ui.ChatHistory.UserMessage current
        local function changed(continued)
            local _, session = enabled_skeptic()
            end_turn(session, add_prompt(session, "one"))
            extracts[1].on_done({ "a" }, nil)
            answer({ reply(1, "supported"), reply(1, "supported") })

            session:emit("session_changed", { continued = continued })
            session.chat_history = ChatHistory:new()
            add_prompt(session, "old")
            add_reply(session, "old reply")
            local current = add_prompt(session, "now")
            add_reply(session, "new reply")
            return session, current
        end

        it("counts the installed history as checked", function()
            local session, current = changed(true)

            end_turn(session, current)

            assert.same({ "now" }, extracts[2].turn.prompts)
            assert.equal("new reply", extracts[2].turn.text)
        end)

        it(
            "keeps the checked claims when the conversation continues",
            function()
                local session, current = changed(true)

                end_turn(session, current)

                assert.same({ "a" }, extracts[2].checked)
            end
        )

        it("forgets the checked claims otherwise", function()
            local session, current = changed(false)

            end_turn(session, current)

            assert.same({}, extracts[2].checked)
        end)

        it("drops a check of the previous conversation", function()
            local _, session = enabled_skeptic()
            end_turn(session, add_prompt(session, "one"))

            session:emit("session_changed", { continued = false })
            extracts[1].on_done({ "a" }, nil)

            for _, agent in ipairs(agents) do
                assert.equal(0, #agent.prompts)
            end
        end)

        it("restarts the agents in the session's new directory", function()
            local _, session = enabled_skeptic()
            session.cwd = function()
                return "/elsewhere"
            end

            session:emit("session_changed", { continued = false })

            assert.is_true(agents[1].destroyed)
            assert.equal("/elsewhere", agents[#agents].opts.cwd)
        end)

        it("keeps the agents and the running check when continued", function()
            local _, session = enabled_skeptic()
            end_turn(session, add_prompt(session, "one"))

            session:emit("session_changed", { continued = true })
            extracts[1].on_done({ "a" }, nil)

            assert.equal(#Config.skeptic.skeptics, #agents)
            assert.equal(1, #agents[1].prompts)
        end)
    end)

    describe("command", function()
        it("turns on and off", function()
            local skeptic = Skeptic:new(fake_session())

            skeptic:command("on")
            assert.is_true(skeptic._enabled)
            skeptic:command("off")
            assert.is_false(skeptic._enabled)
        end)

        it("gives the usage for another argument", function()
            local skeptic = Skeptic:new(fake_session())

            skeptic:command("restart")

            assert.equal("Usage: /skeptic [on|off]", notify_stub.calls[1][1])
        end)

        it("reports the state without an argument", function()
            local skeptic = Skeptic:new(fake_session())

            skeptic:command(nil)

            assert.equal("Skeptic is off", notify_stub.calls[1][1])
        end)
    end)

    describe("setup", function()
        it("registers /skeptic and a skeptic for each new session", function()
            local register_stub =
                spy.stub(SessionManager, "register_local_command")
            local on_create_stub = spy.stub(SessionRegistry, "on_create")
            local original_enabled = Config.skeptic.enabled
            Config.skeptic.enabled = true
            MiniTest.finally(function()
                register_stub:revert()
                on_create_stub:revert()
                Config.skeptic.enabled = original_enabled
            end)

            require("agentic.skeptic").setup()

            assert.equal("skeptic", register_stub.calls[1][1])
            local session = fake_session()
            on_create_stub.calls[1][1](session)
            assert.is_true(session.extensions.skeptic._enabled)

            register_stub.calls[1][2].run(session, "off")
            assert.is_false(session.extensions.skeptic._enabled)
        end)
    end)
end)
