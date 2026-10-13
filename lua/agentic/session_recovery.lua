-- Recovery flows for the session manager:
--   - Login through the provider's ACP auth methods (/login), offered after an
--     auth error.
--   - Conversation-preserving subprocess respawn, after a usage_limit stall or
--     a re-login the subprocess did not survive.
--   - Auto-continue retry after usage_limit errors.
--   - Silent auto-retry after transient server errors.
--   - Surfacing of "successful but empty" prompt responses.
--   - Return of a refused prompt: its text and context go back to the input,
--     and everything queued behind it becomes draft.
-- All functions take the SessionManager (`sm`) as the first argument and
-- read/write its fields (`_retry_*`, `_session_epoch`, `destroyed`, ...).
-- LuaLS treats those underscore-prefixed fields as private to SessionManager;
-- this module is a tightly-coupled helper that legitimately reaches in.
--- @diagnostic disable: invisible

local ACPClient = require("agentic.acp.acp_client")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Glyphs = require("agentic.glyphs")
local Logger = require("agentic.utils.logger")

local M = {}

--- The methods of `methods` this client can run.
--- @param methods agentic.acp.AuthMethod[]
--- @return agentic.acp.AuthMethod[] runnable
local function runnable_auth_methods(methods)
    return vim.tbl_filter(function(method)
        return ACPClient.auth_method_kind(method) ~= nil
    end, methods)
end

--- Surface a successful prompt response with a non-terminal stopReason
--- (`max_tokens`, `max_turn_requests`, `refusal`). These arrive on the
--- success path of `session/prompt` — `err` is nil — so a chat that only
--- inspects errors would silently miss them. `end_turn` and `cancelled`
--- are the normal terminal/user-acknowledged reasons and are skipped.
--- @param sm agentic.SessionManager
--- @param response table|nil
function M.surface_unexpected_response(sm, response)
    if type(response) ~= "table" then
        return
    end

    local stop_reason = response.stopReason
    if
        stop_reason == nil
        or stop_reason == "end_turn"
        or stop_reason == "cancelled"
    then
        return
    end

    local lines = {
        string.format("stopReason: %s", tostring(stop_reason)),
    }
    local usage = type(response.usage) == "table" and response.usage or nil
    if usage then
        for _, key in ipairs({ "inputTokens", "outputTokens", "totalTokens" }) do
            if usage[key] ~= nil then
                table.insert(
                    lines,
                    string.format("usage.%s: %s", key, tostring(usage[key]))
                )
            end
        end
    end

    --- @type agentic.acp.ACPError
    local synthetic_error = {
        code = 0,
        message = table.concat(lines, "\n"),
    }
    sm.message_writer:write_error_message(synthetic_error)
end

--- Give a refused prompt back for editing. Every queued block becomes draft,
--- and a deferred prompt with no buffer range goes into the session's input,
--- since both expected the prompt to succeed. A held synthetic "continue" is
--- indistinguishable from the user's own and goes in too. The prompt's text
--- goes on top of the input in `bufnr` and the context panels it consumed are
--- attached again. The provider keeps the refused message in its
--- conversation, so the restored history and system info it carried are not
--- sent again. Writes what was returned and the number of drafted prompts to
--- the chat.
--- @param sm agentic.SessionManager
--- @param text string The refused prompt as the user wrote it
--- @param consumed agentic.SessionManager.PanelContext What the prompt took from the context panels
--- @param bufnr integer|nil Input to put the text in, default the session's input
function M.restore_refused_prompt(sm, text, consumed, bufnr)
    local input = sm.widget.buf_nrs.input
    local count = sm.widget:queued_block_count()
    sm.widget:cancel_queue()
    if sm._pending_bufferless_prompt then
        BufHelpers.prepend_draft(input, sm._pending_bufferless_prompt)
        sm._pending_bufferless_prompt = nil
        count = count + 1
    end

    BufHelpers.prepend_draft(bufnr or input, text)

    for _, selection in ipairs(consumed.selections) do
        sm.code_selection:add(selection)
    end
    for _, file in ipairs(consumed.files) do
        sm.file_list:add(file)
    end
    sm.diagnostics_list:add_many(consumed.diagnostics)

    local key = Config.keymaps.widget.switch_model
    if type(key) == "string" and key ~= "" then
        sm.message_writer:write_error_action(
            string.format(
                "Prompt returned to the input. Switch model with [%s] to send it again.",
                key
            )
        )
    else
        sm.message_writer:write_error_action("Prompt returned to the input.")
    end
    if count > 0 then
        sm.message_writer:write_error_action(
            string.format("%d held or queued prompt(s) left as draft.", count)
        )
    end
end

--- Point the user at /login after an auth error, when the agent advertises a
--- way to log in.
--- @param sm agentic.SessionManager
function M.offer_login(sm)
    if #runnable_auth_methods(sm.agent.auth_methods or {}) > 0 then
        sm.message_writer:write_error_action("Run /login to re-authenticate.")
    end
end

--- The auth method to run, from those of `methods` this client can run: the
--- one `arg` names, else the one `preferred_id` names, else the only one.
--- @param methods agentic.acp.AuthMethod[] Advertised methods
--- @param arg string Requested method id, or ""
--- @param preferred_id string|nil Method id to use when `arg` is ""
--- @return agentic.acp.AuthMethod|nil method Nil when several fit and none is named, or on a problem
--- @return string|nil problem Why there is nothing to run: no runnable method, or an `arg` naming none
function M.resolve_auth_method(methods, arg, preferred_id)
    local runnable = runnable_auth_methods(methods)
    if #runnable == 0 then
        return nil, "No login method this client can run."
    end

    local wanted_id = arg ~= "" and arg or preferred_id
    for _, method in ipairs(runnable) do
        if method.id == wanted_id then
            return method, nil
        end
    end

    if arg ~= "" then
        local ids = vim.tbl_map(function(method)
            return method.id
        end, runnable)
        return nil,
            string.format(
                "No login method '%s'. Available: %s.",
                arg,
                table.concat(ids, ", ")
            )
    end
    if #runnable == 1 then
        return runnable[1], nil
    end
    return nil, nil
end

--- Log in with one of the agent's auth methods, asking with `vim.ui.select`
--- when several fit and `arg` names none. Writes the problem to the chat when
--- there is nothing to run.
--- @param sm agentic.SessionManager
--- @param arg string Method id, or "" for the configured or only method
--- @param on_done fun() Called once the login finishes, or at once when nothing runs
function M.login(sm, arg, on_done)
    local agent = sm.agent
    if agent.auth_methods == nil then
        sm.message_writer:write_error_action(
            string.format(
                "%s is not connected yet.",
                agent.provider_config.name or Config.provider
            )
        )
        on_done()
        return
    end

    local method, problem = M.resolve_auth_method(
        agent.auth_methods,
        arg,
        agent.provider_config.auth_method
    )
    if problem then
        sm.message_writer:write_error_action(problem)
        on_done()
        return
    end
    if method then
        M.run_login(sm, method, on_done)
        return
    end

    vim.ui.select(runnable_auth_methods(agent.auth_methods), {
        prompt = "Log in with",
        --- @param item agentic.acp.AuthMethod
        format_item = function(item)
            return item.description and (item.name .. ": " .. item.description)
                or item.name
        end,
    }, function(choice)
        if choice then
            M.run_login(sm, choice, on_done)
        else
            on_done()
        end
    end)
end

--- What a failed process said about the failure: the first line of its
--- stderr, else of its stdout, else the signal or exit code that ended it.
--- @param result vim.SystemCompleted
--- @return string reason
local function failure_reason(result)
    for _, text in ipairs({ result.stderr, result.stdout }) do
        local line = vim.trim(text or ""):match("[^\n]+")
        if line then
            return line
        end
    end
    if result.signal ~= 0 then
        return "signal " .. result.signal
    end
    return "exit " .. result.code
end

--- Run one auth method, then recover the session if it succeeded. The login
--- belongs to the provider subprocess, which sessions on one provider share,
--- so one runs per client: a running login is stopped first, which lets a
--- login left waiting on an abandoned browser page be started over.
--- @param sm agentic.SessionManager
--- @param method agentic.acp.AuthMethod An `agent` or `terminal` method
--- @param on_done fun() Called once the login has finished or been stopped, or at once when it does not start
function M.run_login(sm, method, on_done)
    local agent = sm.agent
    if agent.login_job then
        M.stop_login(sm)
        Logger.notify("Stopped the running login.")
    end

    -- The conversation can be replaced during the login (`/new`, a restore, a
    -- provider switch, `/delete`); recovering into the replacement would
    -- recover the wrong conversation.
    local epoch = sm._session_epoch
    --- This login's `login_job`. Once `stop_login` has cleared it, or another
    --- login has taken its place, this login's outcome is no longer reported.
    --- @type vim.SystemObj|table|nil
    local job

    --- @param ok boolean
    --- @param reason string|nil Why it failed
    local function finish(ok, reason)
        local stopped = agent.login_job ~= job
        if not stopped then
            agent.login_job = nil
        end
        on_done()
        if stopped or sm.destroyed or epoch ~= sm._session_epoch then
            return
        end
        if ok then
            M.recover_after_reauth(sm)
        else
            Logger.notify(
                string.format("Login with %s failed: %s", method.name, reason),
                vim.log.levels.WARN
            )
        end
    end

    Logger.notify(string.format("Logging in with %s…", method.name))

    if ACPClient.auth_method_kind(method) == "terminal" then
        -- No pty: a method that needs one to interact (claude-agent-acp's
        -- `claude-login`, offered over SSH) fails, and its error is reported.
        local invocation = agent:terminal_auth_invocation(method)
        local started, result = pcall(
            vim.system,
            invocation.cmd,
            { env = invocation.env, text = true },
            function(completed)
                vim.schedule(function()
                    finish(
                        completed.code == 0 and completed.signal == 0,
                        failure_reason(completed)
                    )
                end)
            end
        )
        if not started then
            Logger.notify(
                string.format("Login with %s failed: %s", method.name, result),
                vim.log.levels.WARN
            )
            on_done()
            return
        end
        job = result
        agent.login_job = job
        return
    end

    -- A fresh table per request, so a stopped request's response cannot pass
    -- for a later one's.
    job = {} --[[@as table]]
    agent.login_job = job
    agent:authenticate(method.id, function(err)
        finish(not err, err and err.message)
    end)
end

--- Stop the login this session's client is running, including one another
--- session on the same client started. A terminal method's process is killed.
--- An `authenticate` request cannot be withdrawn: the agent still answers it,
--- unreported, and may still be handling it when the next login starts.
--- @param sm agentic.SessionManager
function M.stop_login(sm)
    local job = sm.agent.login_job
    if job and job.kill then
        job:kill("sigterm")
    end
    sm.agent.login_job = nil
end

--- Recover the session after a successful re-login.
---
--- Usually there is nothing to recover: the bridge rejects the turn but leaves
--- the subprocess and its query stream up, so the live session takes the next
--- prompt with the refreshed credentials. A subprocess that did exit — the case
--- `1ccfdaa` was written for — shows up as a non-`ready` `agent.state`, since
--- the transport reports the exit as `disconnected`; that one respawns, keeping
--- the conversation.
---
--- The live branch is taken at most once per unresolved auth failure. Whether a
--- running query picks up the refreshed credentials is unknowable from here
--- (the CLI is a compiled binary), so `_reauth_live_retry` records that the
--- cheap recovery has been spent and a second auth error respawns rather than
--- offering the same retry forever. A successful turn clears it — that is the
--- only evidence the credentials took — so the flag deliberately outlives
--- `/new` and a restore, where nothing about the subprocess has been settled.
--- @param sm agentic.SessionManager
function M.recover_after_reauth(sm)
    if
        not sm._reauth_live_retry
        and sm.agent
        and sm.agent.state == "ready"
        and sm.session_id
    then
        sm._reauth_live_retry = true
        M._announce_reauth(sm)
        return
    end

    M.respawn_preserving_history(sm, function()
        M._announce_reauth(sm, {
            "New session — your conversation is re-sent as context on the next message.",
        })
    end)
end

--- Record the re-login in the chat as a landmark the reader can scroll back to.
--- @param sm agentic.SessionManager
--- @param body string[]|nil Lines under the heading
function M._announce_reauth(sm, body)
    sm.message_writer:write_notice({
        glyph = Glyphs.AUTH,
        title = "re-authenticated",
        body = body,
        -- The OAuth round-trip is long enough for the user to have submitted
        -- again while it ran.
        mid_turn = sm.is_generating,
    })
end

--- Cancel a pending auto-continue timer and remove the cancel keymap.
--- @param sm agentic.SessionManager
--- @param reset_attempts? boolean Also reset the retry attempt counter (default: true)
function M.cancel_retry_timer(sm, reset_attempts)
    if sm._retry_timer then
        sm._retry_timer:stop()
        sm._retry_timer:close()
        sm._retry_timer = nil
    end

    local km = sm._retry_keymap
    if km then
        if vim.api.nvim_buf_is_valid(km.bufnr) then
            pcall(vim.keymap.del, "n", km.lhs, { buffer = km.bufnr })
        end
        sm._retry_keymap = nil
    end

    if reset_attempts ~= false then
        sm._retry_attempt = 0
    end
end

--- Replace the provider subprocess while keeping the conversation.
--- The replacement ACP session is empty provider-side, so the prior messages
--- are queued as context for the next submit.
--- @param sm agentic.SessionManager
--- @param on_created fun()|nil Runs after the replacement session is created
function M.respawn_preserving_history(sm, on_created)
    local AgentInstance = require("agentic.acp.agent_instance")
    local provider_name = Config.provider

    local saved_history = sm.chat_history

    -- Stopping the instance disconnects the transport, which fails every
    -- request callback still pending on it rather than orphaning them.
    AgentInstance.invalidate(provider_name)
    sm.session_id = nil
    sm.permission_manager:cancel_requests()
    sm.todo_list:clear()

    sm.agent = AgentInstance.get_instance(provider_name, function(client)
        vim.schedule(function()
            if sm.destroyed then
                return
            end
            sm.agent = client

            sm:new_session({
                restore_mode = true,
                quiet_welcome = true,
                on_created = function()
                    sm:_adopt_history(saved_history)
                    if on_created then
                        on_created()
                    end
                end,
            })
        end)
    end)
end

--- Format seconds into a human-readable duration (e.g. "2h 15m", "45m", "30s").
--- @param seconds number
--- @return string
function M.format_duration(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return string.format("%dh %dm", h, m)
    elseif m > 0 then
        return string.format("%dm", m)
    end
    return string.format("%ds", seconds)
end

--- Schedule auto-continue after a usage limit error.
--- On the first attempt, waits until `reset_epoch + 2 min`. On subsequent
--- attempts (provider's reset time was inaccurate), retries with a fixed
--- 5-minute backoff. Gives up after 3 consecutive attempts.
--- @param sm agentic.SessionManager
--- @param reset_epoch number Epoch seconds when usage resets
function M.offer_auto_continue(sm, reset_epoch)
    if not Config.auto_continue_on_usage_limit then
        return
    end

    local MAX_RETRIES = 3
    local RETRY_BACKOFF_S = 5 * 60 -- 5 minutes

    if sm._retry_attempt >= MAX_RETRIES then
        sm.message_writer:write_error_action(
            string.format(
                "Auto-continue gave up after %d attempts. Send a message manually when usage resets.",
                MAX_RETRIES
            )
        )
        sm._retry_attempt = 0
        return
    end

    M.cancel_retry_timer(sm, false)

    local delay_s
    if sm._retry_attempt > 0 then
        -- Previous auto-continue got another usage limit error — the provider's
        -- reset time was inaccurate. Use a fixed backoff instead.
        delay_s = RETRY_BACKOFF_S
    else
        delay_s = math.max(reset_epoch - os.time(), 10)
        -- Add buffer to avoid racing the exact reset moment
        delay_s = delay_s + 120
    end

    sm._retry_attempt = sm._retry_attempt + 1

    local duration = M.format_duration(delay_s)
    local attempt_suffix = sm._retry_attempt > 1
            and string.format(
                " (attempt %d/%d)",
                sm._retry_attempt,
                MAX_RETRIES
            )
        or ""

    sm.message_writer:write_error_action(
        string.format(
            "Auto-continuing in %s%s. Press [c] to cancel.",
            duration,
            attempt_suffix
        )
    )

    local chat_bufnr = sm.widget.buf_nrs.chat
    local lhs = "c"

    vim.keymap.set("n", lhs, function()
        M.cancel_retry_timer(sm)
        Logger.notify("Auto-continue cancelled.")
    end, { buffer = chat_bufnr, nowait = true })

    sm._retry_keymap = { bufnr = chat_bufnr, lhs = lhs }

    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    sm._retry_timer = timer

    timer:start(
        delay_s * 1000,
        0,
        vim.schedule_wrap(function()
            M._fire_auto_continue(sm)
        end)
    )
end

--- Resume after a usage-limit pause: send whatever the user queued during it,
--- or a bare "continue" if they queued nothing.
--- @param sm agentic.SessionManager
function M._fire_auto_continue(sm)
    M.cancel_retry_timer(sm, false)
    -- Release the gate before dispatching. It would otherwise defer both
    -- branches below and the pause would never end.
    sm._usage_reset_epoch = nil

    if sm.destroyed then
        return
    end

    if not sm.session_id then
        -- Nothing is lost: whatever the user typed during the pause is still
        -- tagged and visible in the input buffer, and drains at the next
        -- benign gate-clear edge.
        Logger.notify(
            "No active session for auto-continue.",
            vim.log.levels.WARN
        )
        return
    end

    -- Whatever the user left held IS the continuation. A bare "continue" only
    -- when they left nothing — sending one in front of a held prompt would put
    -- an unasked-for turn ahead of theirs. The turn started here reaches its
    -- own Stop, where the next drain runs; draining again now would fire a
    -- second concurrent send_prompt.
    if not sm:_dispatch_deferred_prompts() then
        sm:_handle_input_submit("continue")
    end
end

--- How many consecutive transient failures are retried before the error
--- surfaces. Each attempt is a full turn, so the budget also bounds how much
--- work an unrecoverable failure (offline machine, sustained 529) repeats.
local MAX_TRANSIENT_RETRIES = 3

--- Whether a failed turn will be resent as a fresh prompt.
---
--- Answers the caller's real question — "does a retry go out?" — because the
--- caller suppresses the error block, bell, completion hook and queue drain on
--- the strength of this one answer. Every reason a retry could not be
--- dispatched therefore has to be decided here, or a declined retry would
--- leave the failure with nothing reporting it.
---
--- Classification is keyed on the bridge's structured `errorKind` rather than
--- message text, and deliberately kept off MessageWriter's display axis:
--- mapping `server_error` into `error_kind_class` would outrank an embedded 529
--- `overloaded_error` and cost it its hint. Retryability and display class are
--- independent axes.
---
--- `server_error` covers mid-stream truncation, 529 overload and
--- connection-refused/ENOTFOUND alike, and nothing structural separates them
--- (a CLI-generated 529 is prose, but JSON-bearing 529s also exist). The
--- unrecoverable subsets burn the budget in fast failures and then surface as
--- a normal error block. Bridges that attach no `data` never retry.
--- @param sm agentic.SessionManager
--- @param err agentic.acp.ACPError
--- @param turn_session_id string|nil Session the failed turn was sent to
--- @return boolean should_retry
function M.should_retry_transient(sm, err, turn_session_id)
    if not Config.auto_retry_on_transient_error then
        return false
    end
    if type(err.data) ~= "table" or err.data.errorKind ~= "server_error" then
        return false
    end
    if sm.destroyed or sm._transient_attempt >= MAX_TRANSIENT_RETRIES then
        return false
    end
    -- A pending session/prompt callback outlives cancel_session, which drops
    -- the subscriber but not ACPClient.callbacks. So this failure can arrive
    -- after /new, a restore or a provider switch installed a different
    -- session — resending would inject an unprompted turn into it.
    if sm.session_id == nil or sm.session_id ~= turn_session_id then
        return false
    end
    -- Another turn is already outstanding: the user submitted mid-turn and has
    -- taken over. A silent resend would land behind their prompt and read as a
    -- follow-up to it, so the failure is reported instead.
    if sm._prompt_pending > 0 then
        return false
    end
    -- send_prompt has no ready-state guard of its own (unlike
    -- _handle_input_submit, which defers). Writing to an
    -- up-but-not-ready subprocess would leave is_generating stuck true.
    return sm.agent ~= nil and sm.agent.state == "ready"
end

--- Resume a turn that died on a transient server error.
--- ACP has no turn-level resume — `session/resume` re-attaches to a *session*,
--- and only `session/prompt` makes an agent generate — so a fresh prompt on the
--- still-live session is the whole recovery. `failActive` rejects the turn
--- without tearing down the provider's consumer, so no respawn is needed. No
--- delay: the retry goes out immediately.
--- Only call when `should_retry_transient` returned true; it owns the guards.
--- @param sm agentic.SessionManager
function M.retry_after_transient_error(sm)
    -- Increment before dispatch, not after: send_prompt's callback can run
    -- synchronously, so a post-dispatch increment never terminates.
    sm._transient_attempt = sm._transient_attempt + 1
    sm:_send_synthetic_prompt("continue")
end

return M
