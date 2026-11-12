local AcpKind = require("agentic.utils.acp_kind")
local AgentInstance = require("agentic.acp.agent_instance")
local BufHelpers = require("agentic.utils.buf_helpers")
local BufferNames = require("agentic.utils.buffer_names")
local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local GrantSafety = require("agentic.utils.grant_safety")
local Logger = require("agentic.utils.logger")
local PermissionManager = require("agentic.ui.permission_manager")
local SessionResume = require("agentic.session_resume")
local SubagentTranscript = require("agentic.ui.subagent_transcript")

--- The only provider whose escalations the tripwire can tell apart: claude's
--- SDK auto-allows read-only Bash without asking.
local PROVIDER = "opencode-acp"

--- Kinds whose run without a permission request trips the session.
--- @type table<string, true>
local GUARDED_KINDS = { edit = true, execute = true }

--- @type agentic.ui.PermissionManager.Policy
local POLICY = {
    tier = "read_only",
    settings_allow = false,
    kinds = { "read", "search" },
}

--- Stop and close a timer from `vim.defer_fn`, unless it fired and closed.
--- @param timer uv.uv_timer_t|nil
local function close_timer(timer)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

--- The transcript heading of a session labelled `label`.
--- @param label string
--- @return agentic.ui.MessageWriter.SubagentInfo
local function subagent_info(label)
    --- @type agentic.ui.MessageWriter.SubagentInfo
    local info = { label = label, mode = "background", confirmed = true }
    return info
end

--- @class agentic.BackgroundSession.Opts
--- @field provider string Only "opencode-acp"
--- @field model? string Model value id, e.g. "litellm/glm-5.3"
--- @field label string Transcript name suffix, e.g. "skeptic glm-5.3"
--- @field cwd string Working directory of the session
--- @field widget agentic.ui.ChatWidget The widget the transcript opens on
--- @field get_config_dir fun(): string Claude's config directory, whose settings.json deny and ask rules apply
--- @field turn_timeout_ms integer Per turn, and for the session to become ready
--- @field max_refusals integer Refusal prompts per `prompt` call before it gives up
--- @field refusal_text string `string.format` pattern; `%s` receives the reason lines
--- @field on_destroy? fun(err: string|nil, ready: boolean) Called once, after the destroy. `err` is the error of a failed start, "disconnected" when the provider process went away, else nil. `ready` is whether the session had become ready.

--- `err` is a fixed word, a stop reason word (`CanonicalToolCall.stop_reason_word`) or an error message.
--- @alias agentic.BackgroundSession.OnDone fun(text: string|nil, err: "timeout"|"refused"|"closed"|"interrupted"|string|nil)

--- One `prompt` call.
--- @class agentic.BackgroundSession.Job
--- @field text string
--- @field on_done agentic.BackgroundSession.OnDone
--- @field refusals integer Refusal prompts sent so far
--- @field answered? boolean `on_done` has run

--- One prompt sent to the agent.
--- @class agentic.BackgroundSession.Turn
--- @field reasons string[] Why each refused call of the turn was refused
--- @field text string[] The agent's message chunks
--- @field timer? uv.uv_timer_t
--- @field abandoned boolean Cancelled by us; its output no longer counts

--- An agent session the plugin drives unattended, with a transcript the user
--- can open like a subagent's. It never prompts: a call its policy does not
--- approve is rejected, and the agent is told why at the turn's end.
--- @class agentic.BackgroundSession
--- @field bufnr integer|nil Transcript buffer, nil until the session exists
--- @field _opts agentic.BackgroundSession.Opts
--- @field _client? agentic.acp.ACPClient
--- @field _session_id? string
--- @field _ready boolean Created, with its model set
--- @field _destroyed boolean
--- @field _jobs agentic.BackgroundSession.Job[] Waiting for the session or the current job
--- @field _job? agentic.BackgroundSession.Job
--- @field _turn? agentic.BackgroundSession.Turn
--- @field _asked table<string, true> Tool call ids with a permission request
--- @field _transcript? agentic.ui.SubagentTranscript
--- @field _history agentic.ui.ChatHistory In memory, never persisted
--- @field _permissions? agentic.ui.PermissionManager
--- @field _start_timer? uv.uv_timer_t Fails the start when the session is not ready in time
local BackgroundSession = {}
BackgroundSession.__index = BackgroundSession

--- Start a session. `prompt` calls wait until it is ready.
--- @param opts agentic.BackgroundSession.Opts
--- @return agentic.BackgroundSession|nil session Nil with a notify for another provider, or when its process cannot be configured
function BackgroundSession:new(opts)
    if opts.provider ~= PROVIDER then
        Logger.notify(
            "Background sessions support "
                .. PROVIDER
                .. " only, not "
                .. opts.provider,
            vim.log.levels.ERROR
        )
        return nil
    end
    self = setmetatable({
        bufnr = nil,
        _opts = opts,
        _ready = false,
        _destroyed = false,
        _jobs = {},
        _asked = {},
        _history = ChatHistory:new(),
    }, self)

    local instance = AgentInstance.get_instance(opts.provider, function(client)
        vim.schedule(function()
            -- A reconnect runs this again.
            if self._destroyed or self._client then
                return
            end
            self._client = client
            client:create_session(
                opts.cwd,
                self:_handlers(),
                function(result, err)
                    self:_on_created(result, err)
                end
            )
        end)
    end, true)
    if not instance then
        return nil
    end
    -- A provider that fails to start never reaches ready, so `on_ready`
    -- never runs.
    self._start_timer = vim.defer_fn(function()
        if not self._ready and not self._destroyed then
            self:_fail_start("timeout")
        end
    end, opts.turn_timeout_ms)
    return self
end

--- @param result agentic.acp.SessionCreationResponse|nil
--- @param err agentic.acp.ACPError|nil
function BackgroundSession:_on_created(result, err)
    if self._destroyed then
        if result then
            self._client:close_session(result.sessionId, function() end)
        end
        return
    end
    if not result then
        self:_fail_start(err and err.message or "no session")
        return
    end
    self._session_id = result.sessionId
    self:_open_transcript()
    self:_set_model(result.configOptions, function(model_err)
        if self._destroyed then
            return
        end
        if model_err then
            self:_fail_start(model_err.message or vim.inspect(model_err))
            return
        end
        self._ready = true
        close_timer(self._start_timer)
        self:_run_next()
    end)
end

--- Set `opts.model` through the config option of category `model`, else the legacy
--- `session/set_model`. Without a model, `on_set` runs at once.
--- @param config_options agentic.acp.ConfigOption[]|nil
--- @param on_set fun(err: agentic.acp.ACPError|nil)
function BackgroundSession:_set_model(config_options, on_set)
    local model = self._opts.model
    if not model then
        on_set(nil)
        return
    end
    local function callback(_result, err)
        on_set(err)
    end
    for _, option in ipairs(config_options or {}) do
        if option.category == "model" then
            self._client:set_config_option(
                self._session_id,
                option.id,
                model,
                callback
            )
            return
        end
    end
    self._client:set_model(self._session_id, model, callback)
end

--- Fail every waiting `prompt` call with `err`, and destroy the session.
--- @param err string
function BackgroundSession:_fail_start(err)
    local jobs = self._jobs
    self._jobs = {}
    for _, job in ipairs(jobs) do
        job.on_done(nil, err)
    end
    self:_destroy(err)
end

function BackgroundSession:_open_transcript()
    local transcript = SubagentTranscript:new(
        BufferNames.format({
            key = BufferNames.short_key(self._session_id --[[@as string]]),
            part = "background",
        }),
        subagent_info(self._opts.label),
        self._opts.widget,
        {
            setup_buf = function(bufnr)
                vim.bo[bufnr].buflisted = Config.background.list_buffers
                BufHelpers.multi_keymap_set(
                    Config.keymaps.widget.stop_generation,
                    bufnr,
                    function()
                        self:stop()
                    end,
                    { desc = "Agentic: Stop background session" }
                )
            end,
            on_reload = function()
                self:_replay()
            end,
            on_write = function() end,
            on_wipeout = function()
                self:destroy()
            end,
        }
    )
    self._transcript = transcript
    self.bufnr = transcript.bufnr

    local permissions = PermissionManager:new(
        transcript.view.writer,
        { agent = transcript.bufnr },
        nil,
        self._opts.get_config_dir
    )
    permissions:set_policy(POLICY)
    for _, root in ipairs(GrantSafety.tmp_roots()) do
        permissions:add_grant_scope(GrantSafety.compile_scope(root, root))
    end
    permissions.on_decided = function(tool_call_id, causes)
        self:_show_causes(tool_call_id, causes)
    end
    self._permissions = permissions
    self:_mark_unmodified()
end

--- Render the transcript again from the in-memory history.
function BackgroundSession:_replay()
    local transcript = self._transcript --[[@as agentic.ui.SubagentTranscript]]
    local subagent = subagent_info(self._opts.label)
    transcript:restart(subagent)
    SessionResume.replay_messages(
        transcript.view.writer,
        self._history.messages,
        function()
            return nil
        end
    )
    transcript:set_header(subagent)
    self:_mark_unmodified()
end

--- Clear the transcript's 'modified': the history in memory renders it again
--- on `:e`, so it holds nothing unsaved.
function BackgroundSession:_mark_unmodified()
    if self._transcript then
        self._transcript:set_modified(false)
    end
end

--- The client handlers. Updates before the transcript opens or after a
--- destroy are dropped, and a permission request then is cancelled.
--- @return agentic.acp.ClientHandlers
function BackgroundSession:_handlers()
    local function live()
        return self._transcript ~= nil and not self._destroyed
    end
    --- @type agentic.acp.ClientHandlers
    return {
        on_session_update = function(update)
            if live() then
                self:_on_session_update(update)
                self:_mark_unmodified()
            end
        end,
        on_tool_call = function(tool_call)
            if live() then
                self:_on_tool_call(tool_call)
                self:_mark_unmodified()
            end
        end,
        on_tool_call_update = function(update)
            if live() then
                self:_on_tool_call_update(update)
                self:_mark_unmodified()
            end
        end,
        on_request_permission = function(request, callback)
            if live() then
                self:_on_request_permission(request, callback)
            else
                callback(nil)
            end
        end,
        on_disconnect = function()
            self:_destroy("disconnected")
        end,
    }
end

--- Write an agent chunk to the transcript and the history, and keep a
--- message chunk's text for the turn. Other updates are provider state.
--- @param update agentic.acp.SessionUpdateMessage
function BackgroundSession:_on_session_update(update)
    local kind = update.sessionUpdate
    if kind ~= "agent_message_chunk" and kind ~= "agent_thought_chunk" then
        return
    end
    --- @cast update agentic.acp.AgentMessageChunk|agentic.acp.AgentThoughtChunk
    local view = self._transcript.view
    local is_message = kind == "agent_message_chunk"
    local chunk, starts_response = update, nil
    if is_message then
        local filtered
        filtered, starts_response = view.response_boundary:filter_chunk(
            update --[[@as agentic.acp.AgentMessageChunk]]
        )
        if not filtered then
            return
        end
        chunk = filtered
    end
    view.writer:write_message_chunk(chunk, starts_response)
    local text = chunk.content and chunk.content.text
    if text then
        self._history:append_agent_text({
            type = is_message and "agent" or "thought",
            text = text,
            provider_name = self._client.provider_config.name,
        }, starts_response)
        local turn = self:_counted_turn()
        if is_message and turn then
            table.insert(turn.text, text)
        end
    end
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function BackgroundSession:_on_tool_call(tool_call)
    local id = tool_call.tool_call_id
    self._transcript.view:write_tool_call(
        self._history,
        tool_call,
        self._permissions:take_causes(id),
        nil
    )
    self:_check_tripwire(id)
end

--- @param update agentic.ui.MessageWriter.ToolCallBase
function BackgroundSession:_on_tool_call_update(update)
    self._transcript.view:update_tool_call(self._history, update)
    self:_check_tripwire(update.tool_call_id)
end

--- Show a tool call's causes on its block and in the history, and take them
--- from the permission manager once shown. No-op once destroyed.
--- @param tool_call_id string
--- @param causes agentic.PermissionCause[]
function BackgroundSession:_show_causes(tool_call_id, causes)
    if self._destroyed then
        return
    end
    if
        self._transcript.view:show_causes(self._history, tool_call_id, causes)
    then
        self._permissions:take_causes(tool_call_id)
        self:_mark_unmodified()
    end
end

--- The current turn, unless we cancelled it: an abandoned turn's output
--- counts for no job.
--- @return agentic.BackgroundSession.Turn|nil
function BackgroundSession:_counted_turn()
    local turn = self._turn
    return turn and not turn.abandoned and turn or nil
end

--- Approve what the policy approves, reject the rest and keep the causes
--- for the turn's refusal prompt. A request without the needed option is
--- cancelled, which the provider treats as a rejection, and gets a reason
--- line of its own.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function BackgroundSession:_on_request_permission(request, callback)
    local permissions = self._permissions --[[@as agentic.ui.PermissionManager]]
    local id = request.toolCall.toolCallId
    self._asked[id] = true
    local kind, tool_call, diff, cwd = permissions:resolve_request(request)
    local verdict = tool_call and permissions:decide(kind, tool_call, diff, cwd)
        or { causes = {} }
    local approved = verdict.allow == true
    local sent, reasons
    if approved then
        sent = PermissionManager.approve(request, callback)
        reasons = {}
    else
        sent = PermissionManager.reject(request, callback)
        reasons = vim.tbl_map(PermissionManager.cause_line, verdict.causes)
    end
    if not sent then
        callback(nil)
        reasons =
            { id .. ": cancelled, the request offers no option to answer it" }
    elseif #reasons == 0 and not approved then
        reasons = { id .. ": rejected, the request names no tool call" }
    end
    local turn = self:_counted_turn()
    if turn then
        vim.list_extend(turn.reasons, reasons)
    end
    permissions:record_causes(id, verdict.causes)
end

--- Stop the session when a guarded call ran (`CanonicalToolCall.ran`)
--- without a permission request and the policy would not have approved it:
--- the provider's own configuration let it through. The command is judged
--- with no start directory, as the call reports none.
--- @param tool_call_id string
function BackgroundSession:_check_tripwire(tool_call_id)
    local tracker = self._transcript.view.writer.tool_call_blocks[tool_call_id]
    if
        not tracker
        or self._asked[tool_call_id]
        or not CanonicalToolCall.ran(tracker)
    then
        return
    end
    local kind = AcpKind.normalise(tracker.kind)
    if not GUARDED_KINDS[kind] then
        return
    end
    local raw_input = kind == "execute" and { command = tracker.argument }
        or { filePath = tracker.argument }
    local verdict = self._permissions:decide(kind, {
        toolCallId = tool_call_id,
        kind = kind,
        rawInput = raw_input,
    } --[[@as agentic.acp.ToolCall]], tracker.diff, nil)
    if verdict.allow == true then
        return
    end
    Logger.notify(
        ("Background session %q stopped: opencode ran a %s call without asking; a managed opencode setting may allow it."):format(
            self._opts.label,
            kind
        ),
        vim.log.levels.ERROR
    )
    self:destroy()
end

--- Send `text`, after the session is ready (created, model set). `on_done`
--- gets the agent's text from the final turn, after refusal retries. Calls
--- run one at a time, in order.
--- @param text string
--- @param on_done agentic.BackgroundSession.OnDone
function BackgroundSession:prompt(text, on_done)
    if self._destroyed then
        on_done(nil, "closed")
        return
    end
    table.insert(self._jobs, { text = text, on_done = on_done, refusals = 0 })
    self:_run_next()
end

function BackgroundSession:_run_next()
    if not self._ready or self._job or #self._jobs == 0 then
        return
    end
    local job = table.remove(self._jobs, 1)
    self._job = job
    self:_send(job.text)
end

--- Send one prompt for the current job, with its turn timeout. A timeout
--- cancels the turn and answers the job "timeout". If the provider has not
--- answered a cancel (from a timeout or `stop`) at the next timeout, the
--- session is destroyed.
--- @param text string
function BackgroundSession:_send(text)
    local view = self._transcript.view
    view.writer:write_user_prompt(text)
    self._history:add_message({
        type = "user",
        text = text,
        timestamp = os.time(),
        provider_name = self._client.provider_config.name,
    })
    view.status_indicator:start("generating")
    self:_mark_unmodified()

    --- @type agentic.BackgroundSession.Turn
    local turn = { reasons = {}, text = {}, abandoned = false }
    self._turn = turn
    self:_arm_timeout(turn)
    self._client:send_prompt(
        self._session_id --[[@as string]],
        { { type = "text", text = text } },
        function(result, err)
            if self._turn == turn then
                self:_end_turn(result, err)
            end
        end
    )
end

--- Start `turn`'s timeout afresh, replacing a running one.
--- @param turn agentic.BackgroundSession.Turn
function BackgroundSession:_arm_timeout(turn)
    close_timer(turn.timer)
    turn.timer = vim.defer_fn(function()
        self:_on_timeout(turn)
    end, self._opts.turn_timeout_ms)
end

--- Cancel `turn`, or destroy the session when `turn` is cancelled already:
--- the provider did not answer the cancel. No-op once `turn` is closed.
--- @param turn agentic.BackgroundSession.Turn
function BackgroundSession:_on_timeout(turn)
    if self._turn ~= turn then
        return
    end
    if not turn.abandoned then
        self:_cancel_turn("timeout")
        return
    end
    Logger.notify(
        ("Background session %q stopped: the provider did not answer a cancel"):format(
            self._opts.label
        ),
        vim.log.levels.ERROR
    )
    self:destroy()
end

--- Answer the current job by how its turn ended. An abandoned turn's job has
--- its answer already. An error or a stop reason fails the job, except:
--- - `end_turn` without refusals gives the job the turn's text.
--- - `end_turn` or `cancelled` with refusals sends the refusal prompt, up to
---   `max_refusals`. opencode ends a turn `cancelled` after a reject.
--- @param result { stopReason?: string }|nil
--- @param err agentic.acp.ACPError|nil
function BackgroundSession:_end_turn(result, err)
    local turn = self._turn --[[@as agentic.BackgroundSession.Turn]]
    local job = self._job --[[@as agentic.BackgroundSession.Job]]
    self:_close_turn()
    local stop_reason = result and result.stopReason
    local refused = #turn.reasons > 0
    local ended = stop_reason == "end_turn"
        or (stop_reason == "cancelled" and refused)
    if turn.abandoned then
        self:_release()
    elseif err then
        self:_finish(nil, err.message or vim.inspect(err))
    elseif not ended then
        self:_finish(
            nil,
            CanonicalToolCall.stop_reason_word(stop_reason or "error")
        )
    elseif not refused then
        self:_finish(table.concat(turn.text), nil)
    elseif job.refusals >= self._opts.max_refusals then
        self:_finish(nil, "refused")
    else
        job.refusals = job.refusals + 1
        self:_send(
            self._opts.refusal_text:format(table.concat(turn.reasons, "\n"))
        )
    end
end

--- End the current turn in the transcript. A later answer to it is ignored.
function BackgroundSession:_close_turn()
    local turn = self._turn
    if not turn then
        return
    end
    self._turn = nil
    close_timer(turn.timer)
    if self._transcript then
        self._transcript.view.writer:finalize_turn()
        self._transcript.view.status_indicator:stop()
        self:_mark_unmodified()
    end
end

--- Call the current job's `on_done`, unless it was answered already.
--- @param text string|nil
--- @param err string|nil
function BackgroundSession:_answer(text, err)
    local job = self._job
    if job and not job.answered then
        job.answered = true
        job.on_done(text, err)
    end
end

--- Free the session for the next job, and start it.
function BackgroundSession:_release()
    self:_close_turn()
    self._job = nil
    self:_run_next()
end

--- Answer the current job, then start the next.
--- @param text string|nil
--- @param err string|nil
function BackgroundSession:_finish(text, err)
    self:_answer(text, err)
    self:_release()
end

--- Stop the current turn and answer its job "interrupted" at once, with no
--- refusal prompt. The session stays usable. No-op without a turn open or
--- when the turn is cancelled already.
function BackgroundSession:stop()
    self:_cancel_turn("interrupted")
end

--- Cancel the open counted turn and answer its job with `err`. The turn
--- stays current until the provider answers the cancel, so the next job
--- cannot receive its output; the provider gets a full turn timeout to
--- answer. No-op without a counted turn open.
--- @param err string
function BackgroundSession:_cancel_turn(err)
    local turn = self:_counted_turn()
    if not turn then
        return
    end
    turn.abandoned = true
    self:_arm_timeout(turn)
    self._client:stop_generation(self._session_id)
    self:_answer(nil, err)
end

--- Close the session and wipe its transcript. Every pending `prompt` call
--- gets "closed".
function BackgroundSession:destroy()
    self:_destroy(nil)
end

--- `destroy`, passing `err` to `on_destroy`.
--- @param err string|nil
function BackgroundSession:_destroy(err)
    if self._destroyed then
        return
    end
    self._destroyed = true
    close_timer(self._start_timer)
    self:_close_turn()
    self:_answer(nil, "closed")
    self._job = nil
    local jobs = self._jobs
    self._jobs = {}
    for _, job in ipairs(jobs) do
        job.on_done(nil, "closed")
    end
    if self._session_id then
        self._client:close_session(self._session_id, function() end)
    end
    if self._transcript then
        self._transcript:destroy()
    end
    if self._opts.on_destroy then
        self._opts.on_destroy(err, self._ready)
    end
end

return BackgroundSession
