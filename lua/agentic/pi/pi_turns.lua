local AgentClient = require("agentic.agent_client")

--- A change in a session's turns: the oldest untaken prompt was taken in, or
--- the foreground work changed state.
--- @alias agentic.pi.TurnSignal
--- | { taken: table }
--- | { turn: agentic.AgentClient.TurnState }

--- How the last assistant message of a run ended.
--- @class agentic.pi.PiTurns.LastStop
--- @field reason string pi's `stopReason`
--- @field error_message? string pi's `errorMessage`

--- The turn state of one pi session, derived from pi's prompt answers and
--- session events: when a prompt is taken in, when a turn starts and how it
--- ends. Prompts are opaque tables of the caller's, handed back when taken
--- in or cancelled.
--- @class agentic.pi.PiTurns
--- @field _untaken table[] Prompts sent and not yet taken in, oldest first
--- @field _queued table<table, true> Untaken prompts pi answered `queued`
--- @field _handled table[] Prompts an extension command handled while a turn ran
--- @field _running boolean A turn runs
--- @field _took_prompt boolean The running turn has taken in a prompt
--- @field _last_stop? agentic.pi.PiTurns.LastStop
local PiTurns = {}
PiTurns.__index = PiTurns

--- pi's `stopReason` → ACP stop reason.
--- @type table<string, agentic.acp.StopReason>
local STOP_REASONS = {
    stop = "end_turn",
    toolUse = "end_turn",
    deferred = "end_turn",
    length = "max_tokens",
    aborted = "cancelled",
}

--- @return agentic.pi.PiTurns
function PiTurns:new()
    return setmetatable({
        _untaken = {},
        _queued = {},
        _handled = {},
        _running = false,
        _took_prompt = false,
    }, self)
end

--- Hold a prompt sent and not yet taken in.
--- @param prompt table
function PiTurns:on_send(prompt)
    table.insert(self._untaken, prompt)
end

--- Remove `prompt` from the untaken prompts.
--- @param prompt table
--- @return boolean removed
function PiTurns:_drop(prompt)
    self._queued[prompt] = nil
    for i, held in ipairs(self._untaken) do
        if held == prompt then
            table.remove(self._untaken, i)
            return true
        end
    end
    return false
end

--- The oldest untaken prompt, removed.
--- @return table prompt
function PiTurns:_take()
    local prompt = table.remove(self._untaken, 1)
    self._queued[prompt] = nil
    return prompt
end

--- The `idle` state that ends the running turn.
--- @param aborted boolean pi reported the run aborted
--- @param more boolean Another prompt starts the next turn at once
--- @return agentic.AgentClient.TurnState
function PiTurns:_idle(aborted, more)
    local last = self._last_stop
    --- @type agentic.AgentClient.TurnState
    local state = { state = "idle", more = more }
    if aborted or (last and last.reason == "aborted") then
        state.stop_reason = "cancelled"
    elseif last and last.reason == "error" then
        state.stop_reason = "error"
        state.error = {
            code = AgentClient.ERROR_CODES.INTERNAL_ERROR,
            message = last.error_message or "pi reported an error",
        }
    else
        state.stop_reason = last and STOP_REASONS[last.reason] or "end_turn"
    end
    return state
end

--- The signals of a turn that takes `prompt` in and ends at once.
--- @param prompt table
--- @return agentic.pi.TurnSignal[]
local function instant_turn(prompt)
    return {
        { turn = { state = "running" } },
        { taken = prompt },
        { turn = { state = "idle", stop_reason = "end_turn" } },
    }
end

--- The signals from pi's answer to the `prompt` command that sent `prompt`.
--- A prompt an extension command handled has no run: it gets a turn of its
--- own that ends at once, after the running turn when one runs.
--- @param prompt table
--- @param data table|nil The answer's `data`
--- @param err agentic.AgentClient.Error|nil
--- @return agentic.pi.TurnSignal[]
function PiTurns:on_answer(prompt, data, err)
    if err then
        self:_drop(prompt)
        return {}
    end
    local disposition = data and data.disposition
    if disposition == "queued" then
        for _, held in ipairs(self._untaken) do
            if held == prompt then
                self._queued[prompt] = true
            end
        end
        return {}
    end
    if disposition ~= "handled" or not self:_drop(prompt) then
        return {}
    end
    if self._running then
        table.insert(self._handled, prompt)
        return {}
    end
    return instant_turn(prompt)
end

--- The signals a pi session event gives.
--- @param event table A pi session event
--- @return agentic.pi.TurnSignal[]
function PiTurns:on_event(event)
    --- @type agentic.pi.TurnSignal[]
    local signals = {}
    local message = event.message
    if event.type == "agent_start" then
        if not self._running then
            self._running = true
            table.insert(signals, { turn = { state = "running" } })
        end
    elseif
        event.type == "message_start"
        and message.role == "user"
        and #self._untaken > 0
    then
        if not self._running then
            self._running = true
            table.insert(signals, { turn = { state = "running" } })
        elseif self._took_prompt then
            -- A queued follow-up: the turn of the prompt before it ends here.
            table.insert(signals, { turn = self:_idle(false, true) })
            table.insert(signals, { turn = { state = "running" } })
            self._last_stop = nil
        end
        self._took_prompt = true
        table.insert(signals, { taken = self:_take() })
    elseif event.type == "message_end" and message.role == "assistant" then
        self._last_stop = {
            reason = message.stopReason,
            error_message = message.errorMessage,
        }
    elseif event.type == "agent_settled" and self._running then
        table.insert(
            signals,
            { turn = self:_idle(event.aborted == true, false) }
        )
        self:_settle()
        for _, prompt in ipairs(self._handled) do
            vim.list_extend(signals, instant_turn(prompt))
        end
        self._handled = {}
    end
    return signals
end

--- Forget the running turn.
function PiTurns:_settle()
    self._running = false
    self._took_prompt = false
    self._last_stop = nil
end

--- The signals of the process's exit: a running turn ends with an error.
--- @return agentic.pi.TurnSignal[]
function PiTurns:on_exit()
    if not self._running then
        return {}
    end
    self:_settle()
    self._handled = {}
    return {
        {
            turn = {
                state = "idle",
                stop_reason = "error",
                error = {
                    code = AgentClient.ERROR_CODES.TRANSPORT_ERROR,
                    message = "pi exited",
                },
            },
        },
    }
end

--- Remove the untaken prompts pi answered `queued`: the prompts pi's
--- `clear_queue` drops.
--- @return table[] prompts The removed prompts, oldest first
function PiTurns:cancel_queued()
    local prompts = {}
    local kept = {}
    for _, prompt in ipairs(self._untaken) do
        table.insert(self._queued[prompt] and prompts or kept, prompt)
    end
    self._untaken = kept
    self._queued = {}
    return prompts
end

--- Remove the prompts not yet taken in.
--- @return table[] prompts The removed prompts, oldest first
function PiTurns:cancel_untaken()
    local prompts = self._untaken
    self._untaken = {}
    self._queued = {}
    return prompts
end

return PiTurns
