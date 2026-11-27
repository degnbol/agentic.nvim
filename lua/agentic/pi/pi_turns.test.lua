local PiTurns = require("agentic.pi.pi_turns")
local assert = require("tests.helpers.assert")

--- Feed `events` in order and collect every signal.
--- @param turns agentic.pi.PiTurns
--- @param events table[]
--- @return agentic.pi.TurnSignal[]
local function feed(turns, events)
    local signals = {}
    for _, event in ipairs(events) do
        vim.list_extend(signals, turns:on_event(event))
    end
    return signals
end

local USER = { type = "message_start", message = { role = "user" } }

--- @param reason string
--- @param error_message string|nil
local function assistant_end(reason, error_message)
    return {
        type = "message_end",
        message = {
            role = "assistant",
            stopReason = reason,
            errorMessage = error_message,
        },
    }
end

describe("agentic.pi.PiTurns", function()
    it("starts a turn, takes the prompt and ends at agent_settled", function()
        local turns = PiTurns:new()
        local p1 = { "p1" }
        turns:on_send(p1)
        local signals = feed(turns, {
            { type = "agent_start" },
            USER,
            assistant_end("toolUse"),
            { type = "agent_end" },
            assistant_end("stop"),
            { type = "agent_settled", aborted = false },
        })
        assert.same({
            { turn = { state = "running" } },
            { taken = p1 },
            {
                turn = {
                    state = "idle",
                    stop_reason = "end_turn",
                    more = false,
                },
            },
        }, signals)
        assert.equal(p1, signals[2].taken)
    end)

    it("ends the first turn when a queued prompt is taken in", function()
        local turns = PiTurns:new()
        local p1, p2 = { "p1" }, { "p2" }
        turns:on_send(p1)
        turns:on_send(p2)
        local signals = feed(turns, {
            { type = "agent_start" },
            USER,
            assistant_end("length"),
            USER,
        })
        assert.same({
            { turn = { state = "running" } },
            { taken = p1 },
            {
                turn = {
                    state = "idle",
                    stop_reason = "max_tokens",
                    more = true,
                },
            },
            { turn = { state = "running" } },
            { taken = p2 },
        }, signals)
        assert.equal(p2, signals[5].taken)
    end)

    it("maps an error stop to an error with pi's message", function()
        local turns = PiTurns:new()
        turns:on_send({})
        local signals = feed(turns, {
            { type = "agent_start" },
            USER,
            assistant_end("error", "401 bad key"),
            { type = "agent_settled", aborted = false },
        })
        local idle = signals[#signals].turn
        assert.equal("error", idle.stop_reason)
        assert.equal("401 bad key", idle.error.message)
    end)

    it("reports cancelled for an aborted run", function()
        local turns = PiTurns:new()
        turns:on_send({})
        local signals = feed(turns, {
            { type = "agent_start" },
            USER,
            { type = "agent_settled", aborted = true },
        })
        assert.equal("cancelled", signals[#signals].turn.stop_reason)
    end)

    it("ignores a user message no prompt of the client's sent", function()
        local turns = PiTurns:new()
        assert.same({}, feed(turns, { USER }))
    end)

    it("takes a handled prompt in a turn of its own when idle", function()
        local turns = PiTurns:new()
        local p1 = { "p1" }
        turns:on_send(p1)
        assert.same({
            { turn = { state = "running" } },
            { taken = p1 },
            { turn = { state = "idle", stop_reason = "end_turn" } },
        }, turns:on_answer(p1, { disposition = "handled" }, nil))
        assert.same({}, turns:cancel_untaken())
    end)

    it("holds a handled prompt until the running turn settles", function()
        local turns = PiTurns:new()
        local p1, p2 = { "p1" }, { "p2" }
        turns:on_send(p1)
        turns:on_send(p2)
        feed(turns, { { type = "agent_start" }, USER })
        assert.same({}, turns:on_answer(p2, { disposition = "handled" }, nil))
        local signals = feed(turns, {
            assistant_end("stop"),
            { type = "agent_settled", aborted = false },
        })
        assert.same({
            {
                turn = {
                    state = "idle",
                    stop_reason = "end_turn",
                    more = false,
                },
            },
            { turn = { state = "running" } },
            { taken = p2 },
            { turn = { state = "idle", stop_reason = "end_turn" } },
        }, signals)
        assert.equal(p2, signals[3].taken)
        assert.same({}, turns:cancel_untaken())
    end)

    it("cancels only the prompts pi answered queued", function()
        local turns = PiTurns:new()
        local p1, p2, p3 = { "p1" }, { "p2" }, { "p3" }
        turns:on_send(p1)
        turns:on_send(p2)
        turns:on_send(p3)
        turns:on_answer(p1, { disposition = "started" }, nil)
        turns:on_answer(p2, { disposition = "queued" }, nil)
        local queued = turns:cancel_queued()
        assert.equal(1, #queued)
        assert.equal(p2, queued[1])
        local untaken = turns:cancel_untaken()
        assert.equal(2, #untaken)
        assert.equal(p1, untaken[1])
        assert.equal(p3, untaken[2])
    end)

    it("ends a running turn with an error at a process exit", function()
        local turns = PiTurns:new()
        turns:on_send({})
        assert.same({}, turns:on_exit())
        feed(turns, { { type = "agent_start" }, USER })
        local signals = turns:on_exit()
        assert.equal(1, #signals)
        assert.equal("error", signals[1].turn.stop_reason)
        assert.equal(
            require("agentic.agent_client").ERROR_CODES.TRANSPORT_ERROR,
            signals[1].turn.error.code
        )
        assert.same({}, turns:on_exit())
    end)

    it("drops a rejected prompt and keeps the others", function()
        local turns = PiTurns:new()
        local p1, p2 = { "p1" }, { "p2" }
        turns:on_send(p1)
        turns:on_send(p2)
        assert.same({}, turns:on_answer(p1, nil, { code = -1, message = "x" }))
        local untaken = turns:cancel_untaken()
        assert.equal(1, #untaken)
        assert.equal(p2, untaken[1])
    end)

    it("waits for events for a started or queued prompt", function()
        local turns = PiTurns:new()
        local p1 = { "p1" }
        turns:on_send(p1)
        assert.same({}, turns:on_answer(p1, { disposition = "started" }, nil))
        assert.equal(1, #turns:cancel_untaken())
        assert.same({}, turns:cancel_untaken())
    end)
end)
