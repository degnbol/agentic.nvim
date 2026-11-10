-- Recovery flows for the session manager:
--   - Login through the provider's ACP auth methods (/login), offered after an
--     auth error.
--   - A new ACP session that carries the conversation, after a usage_limit
--     error, and a restart of the provider subprocess for every session on
--     it, after a re-login the live session did not cover.
--   - The automatic "continue" queued after a usage limit.
--   - Silent auto-retry after transient server errors.
--   - Surfacing of "successful but empty" prompt responses.
--   - Return of a refused prompt: its text and context go back to the input,
--     and everything queued behind it becomes draft.
--   - Requeue of a prompt the usage limit turned away.
-- All functions take the SessionManager (`sm`) as the first argument and
-- read/write its fields (`_transient_attempt`, `_session_epoch`, `destroyed`, ...).
-- LuaLS treats those underscore-prefixed fields as private to SessionManager;
-- this module is a tightly-coupled helper that legitimately reaches in.
--- @diagnostic disable: invisible

local ACPClient = require("agentic.acp.acp_client")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Duration = require("agentic.utils.duration")
local Glyphs = require("agentic.glyphs")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")
local UsageLimit = require("agentic.acp.usage_limit")

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

--- Attach the context panel items a prompt consumed again.
--- @param sm agentic.SessionManager
--- @param consumed agentic.SessionManager.PanelContext
local function reattach_context(sm, consumed)
    for _, selection in ipairs(consumed.selections) do
        sm.code_selection:add(selection)
    end
    for _, file in ipairs(consumed.files) do
        sm.file_list:add(file)
    end
    sm.diagnostics_list:add_many(consumed.diagnostics)
end

--- Give a refused prompt back for editing. Every queued block becomes draft,
--- since it was written expecting the prompt to succeed. The prompt's text
--- goes on top of the input in `bufnr` and the context panels it consumed are
--- attached again. The provider keeps the refused message in its conversation, so the
--- history prefix and system info it carried are not sent again. Writes what
--- was returned and the number of drafted prompts to the chat. No-op once the
--- widget is destroyed.
--- @param sm agentic.SessionManager
--- @param text string The refused prompt as the user wrote it
--- @param consumed agentic.SessionManager.PanelContext What the prompt took from the context panels
--- @param bufnr integer|nil Input to put the text in, default the session's input
function M.restore_refused_prompt(sm, text, consumed, bufnr)
    if sm.destroyed then
        return
    end
    local count = sm.widget.input_dispatch:queued_block_count()
    sm.widget.input_dispatch:cancel_queue()
    sm._continue_mark = nil

    BufHelpers.prepend_draft(
        bufnr or sm.widget:panel_buf("input") --[[@as integer]],
        text
    )
    reattach_context(sm, consumed)

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
            string.format("%d queued prompt(s) left as draft.", count)
        )
    end
end

--- Put a prompt the usage limit turned away back in the input, as the first
--- queued region, ahead of the text already queued, and attach the context
--- panels it consumed again. No-op once the widget is
--- destroyed.
--- @param sm agentic.SessionManager
--- @param text string The prompt as the user wrote it
--- @param consumed agentic.SessionManager.PanelContext What the prompt took from the context panels
function M.requeue_limited_prompt(sm, text, consumed)
    if sm.destroyed then
        return
    end
    -- The automatic "continue" stays recognisable, so `/new` and a give-up
    -- still withdraw it.
    local is_auto_continue = sm._continue_mark ~= nil and text == "continue"
    local mark = sm:_queue_input(text, { first = true })
    if is_auto_continue then
        sm._continue_mark = mark
    end
    reattach_context(sm, consumed)
end

--- Put a prompt the usage limit turned away back as a draft on top of the
--- input in `bufnr`, and attach the context panels it consumed again. Leaves
--- the queue alone. No-op once the widget is destroyed.
--- @param sm agentic.SessionManager
--- @param text string The prompt as the user wrote it
--- @param consumed agentic.SessionManager.PanelContext What the prompt took from the context panels
--- @param bufnr integer|nil Input to put the text in, default the session's input
function M.return_limited_prompt(sm, text, consumed, bufnr)
    if sm.destroyed then
        return
    end
    if bufnr then
        BufHelpers.prepend_draft(bufnr, text)
    else
        -- Making the input makes its dispatch.
        sm.widget:panel_buf("input")
        sm.widget.input_dispatch:prepend_draft(text)
    end
    reattach_context(sm, consumed)
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
                agent.provider_config.name or agent.provider_name
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

    -- The conversation can be replaced during the login (`/new`, a resume, a
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
--- the transport reports the exit as `disconnected`; it is restarted, and
--- every session on it continues with its conversation.
---
--- The live branch is taken at most once per unresolved auth failure. Whether a
--- running query picks up the refreshed credentials is unknowable from here
--- (the CLI is a compiled binary), so `_reauth_live_retry` records that the
--- cheap recovery has been spent and a second auth error restarts the
--- subprocess rather than offering the same retry forever. A successful turn
--- clears it — that is the only evidence the credentials took — so the flag
--- deliberately outlives `/new` and a resume, where nothing about the
--- subprocess has been settled.
---
--- It restarts rather than opening a new ACP session because only a restart
--- makes every provider read the credentials again. The credentials belong to
--- the account, so every other session on the subprocess holds the same stale
--- ones and gets a new ACP session too.
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

    M.restart_client(sm, function()
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
        mid_turn = sm:_turn_open(),
    })
end

--- Move the session to a new ACP session on the same client, carrying its
--- model and, as context for the next submit, its conversation. Clears `sm.session_id` and the todo list and cancels pending
--- permission requests at once. The old session is closed first, so its
--- cancelled turns answer before the new session exists. Nothing is created
--- when `sm` is destroyed or moves on (its epoch changes) before then.
--- @param sm agentic.SessionManager
--- @param on_created fun()|nil Runs after the new session is created
function M.renew_session(sm, on_created)
    local old_id = sm.session_id
    local epoch = sm._session_epoch
    local model = sm.config_options:current_model_id()
    sm.session_id = nil
    sm.permission_manager:cancel_requests()
    sm.todo_list:clear()

    local function create()
        if sm.destroyed or sm._session_epoch ~= epoch then
            return
        end
        sm:new_session({
            history = sm.chat_history,
            quiet_welcome = true,
            on_created = function()
                sm:_reapply_model(model)
                if on_created then
                    on_created()
                end
            end,
        })
    end

    if old_id then
        sm.agent:close_session(old_id, create)
    else
        create()
    end
end

--- Restart the provider subprocess of `sm`'s client and move every session on
--- that client to a new ACP session, each carrying its own conversation.
--- Clears each session's `session_id` and cancels its pending permission
--- requests at once. A session destroyed or moved on (its epoch changed)
--- during the restart gets no new ACP session.
--- @param sm agentic.SessionManager
--- @param on_created fun()|nil Runs after `sm`'s new session is created. Does not run when a later restart supersedes this one before it is ready
function M.restart_client(sm, on_created)
    local agent = sm.agent
    -- Sessions without a session_id too: a `session/new` sent to a dead
    -- subprocess fails only at the stop, and leaves its session with none.
    --- @type table<agentic.SessionManager, integer>
    local epochs = {}
    for _, session in pairs(SessionRegistry.by_id) do
        if session.agent == agent then
            epochs[session] = session._session_epoch
        end
    end

    -- Before the restart, so the answers to open permission requests reach
    -- the subprocess that asked, and `renew_session` closes no session on a
    -- subprocess that is gone.
    for session in pairs(epochs) do
        session.permission_manager:cancel_requests()
        session.session_id = nil
    end

    agent:restart(function()
        vim.schedule(function()
            for session, epoch in pairs(epochs) do
                if
                    not session.destroyed
                    and session._session_epoch == epoch
                then
                    M.renew_session(
                        session,
                        session == sm and on_created or nil
                    )
                end
            end
        end)
    end)
end

--- Report when queued prompts send, and queue a "continue" in an empty input
--- so the stopped turn resumes then. Queues nothing when
--- `auto_continue_on_usage_limit` is off, the input holds text or is being
--- typed in, or the limit came back `UsageLimit.MAX_ATTEMPTS` times in a row.
--- @param sm agentic.SessionManager
--- @param limit agentic.acp.UsageLimit The limit the turn hit
function M.offer_auto_continue(sm, limit)
    local auto_continue = sm.agent:auto_continue_on_usage_limit()
    local attempt_suffix = ""
    if
        auto_continue
        and limit.attempt > 1
        and limit.attempt <= UsageLimit.MAX_ATTEMPTS
    then
        attempt_suffix = string.format(
            " (attempt %d/%d)",
            limit.attempt,
            UsageLimit.MAX_ATTEMPTS
        )
    end
    sm.message_writer:write_error_action(
        string.format(
            "Usage limit: queued prompts send in %s%s.",
            Duration.format(limit.lifts_at - os.time()),
            attempt_suffix
        )
    )

    if not auto_continue then
        return
    end
    if limit.attempt > UsageLimit.MAX_ATTEMPTS then
        sm.message_writer:write_error_action(
            string.format(
                "Auto-continue gave up after %d attempts.",
                UsageLimit.MAX_ATTEMPTS
            )
        )
        -- One the limit turned away was queued again.
        sm:_withdraw_auto_continue()
        return
    end
    -- Queued text is already the continuation, and a draft is the user's next
    -- prompt: a turn sent ahead of it changes its context.
    local input = sm.widget:panel_buf("input") --[[@as integer]]
    local typing = vim.api.nvim_get_current_buf() == input
        and BufHelpers.in_insert_mode()
    if typing or not BufHelpers.is_buffer_blank(input) then
        return
    end
    sm._continue_mark = sm:_queue_input("continue")
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
--- message text, and deliberately kept off ErrorReport's display axis:
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
    -- after /new, a resume or a provider switch installed a different
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
--- without tearing down the provider's consumer, so no new session is needed. No
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
