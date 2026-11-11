--- Background skeptics: after each turn of a main session, check the claims
--- it made with agents on other models, and send the disputed ones back to
--- it. `:h agentic-skeptic`

local BackgroundSession = require("agentic.background_session")
local Claims = require("agentic.skeptic.claims")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local Prompts = require("agentic.skeptic.prompts")
local ReportingCriteria = require("agentic.skeptic.reporting_criteria")
local SessionManager = require("agentic.session_manager")
local SessionRegistry = require("agentic.session_registry")
local TextModel = require("agentic.utils.text_model")
local Turn = require("agentic.skeptic.turn")
local Verdicts = require("agentic.skeptic.verdicts")

--- The author of the skeptic's prompts, a key of `Glyphs.AUTHOR`.
local AUTHOR = "skeptic"

--- The `deliver` prompt of `findings`: each claim numbered, with the
--- skeptics' evidence under it.
--- @param findings agentic.skeptic.Finding[]
--- @return string
local function deliver_text(findings)
    local items = {}
    for i, finding in ipairs(findings) do
        local lines = { ("%d. %s"):format(i, finding.claim) }
        for _, evidence in ipairs(finding.evidence) do
            table.insert(lines, "   - " .. evidence)
        end
        table.insert(items, table.concat(lines, "\n"))
    end
    return Prompts.text("deliver"):format(table.concat(items, "\n"))
end

--- One skeptic agent.
--- @class agentic.skeptic.Agent
--- @field label string
--- @field spec agentic.UserConfig.SkepticModel
--- @field session agentic.BackgroundSession

--- The skeptic of one main session, `session.extensions.skeptic`.
--- @class agentic.skeptic.Skeptic
--- @field _session agentic.SessionManager
--- @field _enabled boolean
--- @field _agents agentic.skeptic.Agent[] Nonempty while enabled
--- @field _seen? agentic.skeptic.Seen Nil until a turn ends while enabled, which sets it to before that turn's prompt
--- @field _checked string[] Claims some skeptic gave a verdict on in this conversation
--- @field _carried? agentic.skeptic.Turn User content collected in a turn the skeptic prompted, checked with the next turn
--- @field _running boolean A check runs
--- @field _queued? agentic.skeptic.Turn Collected while a check ran, checked after it
--- @field _held string[] Deliveries the main session held, sent at the next normal turn end
--- @field _generation integer Advanced by a disable or a session change; a check started under an earlier one is dropped
--- @field _unsubscribes fun()[]
local Skeptic = {}
Skeptic.__index = Skeptic

--- Attach a skeptic, off, to `session` as `session.extensions.skeptic`.
--- @param session agentic.SessionManager
--- @return agentic.skeptic.Skeptic
function Skeptic:new(session)
    self = setmetatable({
        _session = session,
        _enabled = false,
        _agents = {},
        _checked = {},
        _running = false,
        _held = {},
        _generation = 0,
    }, self)
    session.extensions.skeptic = self
    self._unsubscribes = {
        session:on("turn_end", function(_, data)
            self:_on_turn_end(data)
        end),
        session:on("session_changed", function(_, data)
            self:_on_session_changed(data.continued == true)
        end),
        session:on("destroy", function()
            self:disable()
            for _, unsubscribe in ipairs(self._unsubscribes) do
                unsubscribe()
            end
        end),
    }
    return self
end

--- Start a skeptic agent per `Config.skeptic.skeptics`. Stays off, with a
--- notify, without `text_model.url` or when no agent starts.
function Skeptic:enable()
    if self._enabled then
        return
    end
    if not TextModel.available() then
        Logger.notify(
            "Skeptic needs `text_model.url` to extract claims",
            vim.log.levels.WARN
        )
        return
    end
    self._enabled = true
    for _, spec in ipairs(Config.skeptic.skeptics) do
        self:_start(spec)
    end
    self:_off_without_agents()
end

--- Turn the skeptic off, with a notify, when it has no agent.
function Skeptic:_off_without_agents()
    if #self._agents == 0 then
        Logger.notify("Skeptic off: no skeptic agent", vim.log.levels.WARN)
        self:disable()
    end
end

--- Start a skeptic agent for `spec` and add it to the agents. Nothing is
--- added, with a notify, when its session cannot be made.
--- @param spec agentic.UserConfig.SkepticModel
function Skeptic:_start(spec)
    local session = self._session
    local cfg = Config.skeptic
    local label = "skeptic " .. spec.model:match("[^/]+$")
    -- Set before `on_destroy` can run: `new` destroys the session only
    -- asynchronously.
    --- @type agentic.skeptic.Agent
    local agent
    local background = BackgroundSession:new({
        provider = spec.provider,
        model = spec.model,
        label = label,
        cwd = session:cwd(),
        widget = session.widget,
        get_config_dir = function()
            return session.agent:claude_config_dir()
        end,
        turn_timeout_ms = cfg.turn_timeout_ms,
        max_refusals = cfg.max_refusals,
        refusal_text = Prompts.text("refusal"),
        on_destroy = function(err, ready)
            self:_on_agent_destroyed(agent, err, ready)
        end,
    })
    if background then
        agent = { label = label, spec = spec, session = background }
        table.insert(self._agents, agent)
    end
end

--- On the next tick, remove `agent` from the agents. With `err`, replace it
--- with a new agent from its spec when it was `ready`, else notify `err` as
--- a failed start. Then turn the skeptic off, with a notify, when no agent
--- is left. A no-op for an agent already removed.
--- @param agent agentic.skeptic.Agent
--- @param err string|nil See `agentic.BackgroundSession.Opts.on_destroy`
--- @param ready boolean
function Skeptic:_on_agent_destroyed(agent, err, ready)
    vim.schedule(function()
        local i = vim.iter(ipairs(self._agents)):find(function(_, a)
            return a == agent
        end)
        -- `disable` removes the agents before it destroys them.
        if not i then
            return
        end
        table.remove(self._agents, i)
        if err and ready then
            self:_start(agent.spec)
        elseif err then
            Logger.notify(
                ("Skeptic %q failed to start: %s"):format(agent.label, err),
                vim.log.levels.WARN
            )
        end
        self:_off_without_agents()
    end)
end

--- Stop the skeptic agents and drop the running check, held deliveries and
--- the mark: once on again, checks start at the next turn's prompt.
function Skeptic:disable()
    self:_drop_check()
    self._enabled = false
    self._held = {}
    self._seen = nil
    self._carried = nil
    local agents = self._agents
    self._agents = {}
    for _, agent in ipairs(agents) do
        agent.session:destroy()
    end
end

--- Run `/skeptic`: `on` or `off`, or report the state without an argument.
--- @param arg string|nil
function Skeptic:command(arg)
    if arg == nil then
        Logger.notify(
            "Skeptic is " .. (self._enabled and "on" or "off"),
            vim.log.levels.INFO
        )
    elseif arg == "on" then
        self:enable()
    elseif arg == "off" then
        self:disable()
    else
        Logger.notify("Usage: /skeptic [on|off]", vim.log.levels.WARN)
    end
end

--- Drop the running check and what waits for it.
function Skeptic:_drop_check()
    self._generation = self._generation + 1
    self._running = false
    self._queued = nil
end

--- Handle a new ACP session: history before the prompt of the next turn to
--- end counts as checked. A conversation that carries on keeps its running
--- check. One that does not also forgets its checked claims and held
--- deliveries, and restarts the skeptic agents, which then start in the
--- session's working directory with no context of the earlier conversation.
--- @param continued boolean
function Skeptic:_on_session_changed(continued)
    self._seen = nil
    if continued then
        return
    end
    self._checked = {}
    self._held = {}
    self._carried = nil
    if self._enabled then
        self:disable()
        self:enable()
    else
        self:_drop_check()
    end
end

--- Collect the turn and check it. A turn that did not end normally is
--- left for the next one that does, so a stopped agent is not restarted. A
--- turn the skeptic prompted is collected and not checked: one round.
--- @param data agentic.SessionEventData
function Skeptic:_on_turn_end(data)
    if not self._enabled then
        return
    end
    local history = self._session.chat_history
    self._seen = self._seen or Turn.seen_before(history, data.user_msg)
    if data.stop_reason ~= "end_turn" then
        return
    end
    local held = self._held
    self._held = {}
    for _, text in ipairs(held) do
        self:_deliver(text)
    end

    local turn = Turn.collect(history, self._seen)
    if data.user_msg and data.user_msg.author == AUTHOR then
        -- The prompts sent during the skeptic's turn and the reports of
        -- subagents that ended in it belong to the user's turns.
        --- @type agentic.skeptic.Turn
        local kept = {
            prompts = turn.prompts,
            text = "",
            diffs = {},
            reports = turn.reports,
        }
        self._carried = self._carried and Turn.merge(self._carried, kept)
            or kept
        return
    end
    if self._carried then
        turn = Turn.merge(self._carried, turn)
        self._carried = nil
    end
    if not Turn.is_empty(turn) then
        self:_check(turn)
    end
end

--- Check `turn`, or merge it into the next check while one runs.
--- @param turn agentic.skeptic.Turn
function Skeptic:_check(turn)
    if self._running then
        self._queued = self._queued and Turn.merge(self._queued, turn) or turn
        return
    end
    self._running = true
    local generation = self._generation
    local function current()
        return generation == self._generation
    end

    Claims.extract(turn, self._checked, function(claims, err)
        if not current() then
            return
        end
        if not claims then
            Logger.notify(
                "Skeptic: claim extraction failed: " .. tostring(err),
                vim.log.levels.WARN
            )
            self:_finish()
            return
        end
        if #claims == 0 then
            self:_finish()
            return
        end
        self:_verify(turn, claims, function(per_skeptic)
            for i, claim in ipairs(claims) do
                for _, verdicts in ipairs(per_skeptic) do
                    if verdicts and verdicts[i] then
                        table.insert(self._checked, claim)
                        break
                    end
                end
            end
            local findings = ReportingCriteria.findings(
                claims,
                per_skeptic,
                Config.skeptic.reporting_criteria
            )
            if #findings > 0 then
                self:_deliver(deliver_text(findings))
            end
            self:_finish()
        end)
    end)
end

--- End the running check, and start the queued one.
function Skeptic:_finish()
    self._running = false
    local queued = self._queued
    self._queued = nil
    if queued then
        self:_check(queued)
    end
end

--- Ask every skeptic agent for verdicts on `claims`. `on_done` gets each
--- agent's verdicts, false for one that failed or gave none, once all
--- answered, unless the check was dropped meanwhile.
--- @param turn agentic.skeptic.Turn
--- @param claims string[]
--- @param on_done fun(per_skeptic: (table<integer, agentic.skeptic.Verdict>|false)[])
function Skeptic:_verify(turn, claims, on_done)
    local text = Prompts.text("verify"):format(Prompts.join({
        Prompts.section("User prompts", turn.prompts),
        Prompts.section("Claims", Prompts.numbered(claims)),
        Prompts.section("Diffs", turn.diffs),
    }))
    local agents = self._agents
    local generation = self._generation
    --- @type (table<integer, agentic.skeptic.Verdict>|false)[]
    local per_skeptic = {}
    local n_pending = #agents
    for i, agent in ipairs(agents) do
        agent.session:prompt(text, function(reply, err)
            if generation ~= self._generation then
                return
            end
            local verdicts = reply and Verdicts.parse(reply)
            if not reply then
                Logger.notify(
                    ("Skeptic %q failed: %s"):format(agent.label, tostring(err)),
                    vim.log.levels.WARN
                )
            elseif not verdicts then
                Logger.notify(
                    ("Skeptic %q gave no verdicts"):format(agent.label),
                    vim.log.levels.WARN
                )
            end
            per_skeptic[i] = verdicts or false
            n_pending = n_pending - 1
            if n_pending == 0 then
                on_done(per_skeptic)
            end
        end)
    end
end

--- Send `text` to the main session as the skeptic, or keep it for the next
--- normal turn end when the session holds it.
--- @param text string
function Skeptic:_deliver(text)
    if self._session:send_from(AUTHOR, text) then
        table.insert(self._held, text)
    end
end

--- @class agentic.skeptic
local M = {}

M.Skeptic = Skeptic

--- Register `/skeptic`, and give every new session a skeptic, on when
--- `Config.skeptic.enabled`.
function M.setup()
    SessionManager.register_local_command("skeptic", {
        takes_arg = true,
        description = "Background skeptics: /skeptic [on|off]; no argument reports the state",
        run = function(session, arg)
            session.extensions.skeptic:command(arg)
        end,
    })
    SessionRegistry.on_create(function(session)
        local skeptic = Skeptic:new(session)
        if Config.skeptic.enabled then
            skeptic:enable()
        end
    end)
end

return M
