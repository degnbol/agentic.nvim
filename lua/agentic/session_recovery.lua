-- Recovery flows for the session manager:
--   - Re-authentication when the Claude provider returns an auth error.
--   - Server-health backoff before offering reauth.
--   - Provider subprocess restart after re-authentication.
--   - Auto-continue retry after usage_limit errors.
--   - Surfacing of "successful but empty" prompt responses.
-- All functions take the SessionManager (`sm`) as the first argument and
-- read/write its fields (`_reauth_keymap`, `_health_check_timer`,
-- `_retry_*`, `_reauth_job`, `_destroyed`, ...). LuaLS treats those
-- underscore-prefixed fields as private to SessionManager; this module is
-- a tightly-coupled helper that legitimately reaches in.
--- @diagnostic disable: invisible

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

local M = {}

local function is_claude_provider()
    return Config.provider == "claude-acp"
        or Config.provider == "claude-agent-acp"
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
    if stop_reason == nil or stop_reason == "end_turn" or stop_reason == "cancelled" then
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

--- Offer re-authentication after a Claude auth error.
--- Checks server health first — if unreachable, polls with exponential
--- backoff until the server is back, then offers the `r` keymap.
--- @param sm agentic.SessionManager
function M.offer_reauth(sm)
    if not is_claude_provider() then
        return
    end

    M._check_server_then_offer_reauth(sm, 1)
end

--- Set up the [r] keymap to trigger `claude auth login`.
--- @param sm agentic.SessionManager
function M._set_reauth_keymap(sm)
    sm.message_writer:write_error_action(
        "Press [r] to re-authenticate in browser."
    )

    local chat_bufnr = sm.widget.buf_nrs.chat
    local lhs = "r"

    vim.keymap.set("n", lhs, function()
        M.run_reauth(sm)
    end, { buffer = chat_bufnr, nowait = true })

    sm._reauth_keymap = { bufnr = chat_bufnr, lhs = lhs }
end

--- Health check URL for Claude's API infrastructure.
local HEALTH_CHECK_URL = "https://api.anthropic.com"

--- Check if the Claude server is reachable before offering reauth.
--- If unreachable, retries with exponential backoff (30s, 60s, 120s, ...).
--- When reachable, sets up the [r] keymap so the user can authenticate.
--- @param sm agentic.SessionManager
--- @param attempt number Current attempt number (1-based)
function M._check_server_then_offer_reauth(sm, attempt)
    local max_delay_s = 600 -- cap at 10 minutes
    local base_delay_s = 30
    local delay_s = math.min(base_delay_s * (2 ^ (attempt - 1)), max_delay_s)

    sm.message_writer:write_error_action(
        string.format("Checking server health (%s)...", HEALTH_CHECK_URL)
    )

    vim.system({
        "curl",
        "-s",
        "-o",
        "/dev/null",
        "--connect-timeout",
        "5",
        HEALTH_CHECK_URL,
    }, {}, function(result)
        vim.schedule(function()
            if sm._destroyed then
                return
            end

            if result.code == 0 then
                -- Server reachable — offer login
                M._set_reauth_keymap(sm)
            else
                -- Server unreachable — schedule retry with backoff
                sm.message_writer:write_error_action(
                    string.format(
                        "Server unreachable. Retrying in %ds... (attempt %d)",
                        delay_s,
                        attempt
                    )
                )

                M.cancel_health_check_timer(sm)
                local timer = vim.uv.new_timer()
                if not timer then
                    return
                end
                sm._health_check_timer = timer
                timer:start(delay_s * 1000, 0, function()
                    -- Nil out immediately so cancel_health_check_timer
                    -- won't call stop/close on an already-closed handle
                    sm._health_check_timer = nil
                    timer:stop()
                    timer:close()
                    vim.schedule(function()
                        if sm._destroyed then
                            return
                        end
                        M._check_server_then_offer_reauth(sm, attempt + 1)
                    end)
                end)
            end
        end)
    end)
end

--- Stop and close the health check backoff timer if active.
--- @param sm agentic.SessionManager
function M.cancel_health_check_timer(sm)
    if sm._health_check_timer then
        sm._health_check_timer:stop()
        sm._health_check_timer:close()
        sm._health_check_timer = nil
    end
end

--- Remove the re-auth keymap if one is active.
--- @param sm agentic.SessionManager
function M.remove_reauth_keymap(sm)
    local km = sm._reauth_keymap
    if not km then
        return
    end

    if vim.api.nvim_buf_is_valid(km.bufnr) then
        pcall(vim.keymap.del, "n", km.lhs, { buffer = km.bufnr })
    end
    sm._reauth_keymap = nil
end

--- Spawn `claude auth login` to re-authenticate via browser OAuth.
--- @param sm agentic.SessionManager
function M.run_reauth(sm)
    M.remove_reauth_keymap(sm)

    if sm._reauth_job then
        Logger.notify("Re-authentication already in progress.")
        return
    end

    local auth_type = Config.auth_type or "claudeai"
    local flag = "--" .. auth_type

    Logger.notify("Opening browser for re-authentication...")

    sm._reauth_job = vim.system(
        { "claude", "auth", "login", flag },
        {},
        function(result)
            vim.schedule(function()
                sm._reauth_job = nil
                if sm._destroyed then
                    return
                end

                if result.code == 0 then
                    Logger.notify("Re-authenticated. Restarting provider...")
                    M.restart_provider(sm)
                else
                    Logger.notify(
                        "Re-authentication failed. Try running 'claude auth login' manually.",
                        vim.log.levels.WARN
                    )
                end
            end)
        end
    )
end

--- Send sigterm to a running reauth job. Used during destroy().
--- @param sm agentic.SessionManager
function M.kill_reauth_job(sm)
    if sm._reauth_job then
        sm._reauth_job:kill("sigterm") --- @diagnostic disable-line: undefined-field
        sm._reauth_job = nil
    end
end

--- Kill the dead cached agent, spawn a fresh provider subprocess,
--- and create a new session. Used after re-authentication when the
--- provider process has exited.
--- @param sm agentic.SessionManager
function M.restart_provider(sm)
    local AgentInstance = require("agentic.acp.agent_instance")

    -- Remove the dead cached instance so get_instance spawns a fresh one
    sm.agent:stop()
    AgentInstance._instances[Config.provider] = nil

    local new_agent = AgentInstance.get_instance(
        Config.provider,
        function(client)
            vim.schedule(function()
                sm.agent = client
                sm:new_session()
            end)
        end
    )

    if new_agent then
        sm.agent = new_agent
    end
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

    sm._queued_prompts = nil

    if reset_attempts ~= false then
        sm._retry_attempt = 0
    end
end

--- Force-respawn the ACP subprocess for the current provider after a
--- usage_limit error. claude-agent-acp's prompt generator does NOT close on
--- RequestError.internalError (acp-agent.js:449-450, 600-609), so the next
--- prompt to the same subprocess returns end_turn with zero usage and no
--- chunks — silent failure. We kill the subprocess immediately so the next
--- prompt (auto-continue or manual) lands on a fresh pipeline. Chat history
--- is preserved and prepended on the next submit via _history_to_send.
--- See chunk-flush.md.
--- @param sm agentic.SessionManager
function M.respawn_after_usage_limit(sm)
    local AgentInstance = require("agentic.acp.agent_instance")
    local provider_name = Config.provider

    local saved_history = sm.chat_history

    -- Kill the stuck subprocess and drop the cached instance so the next
    -- get_instance spawns a fresh one. Pending callbacks fail with the
    -- "disconnected" state via _fail_pending_callbacks.
    AgentInstance.invalidate(provider_name)
    sm.session_id = nil
    sm.permission_manager:clear()
    sm.todo_list:clear()

    local new_agent = AgentInstance.get_instance(provider_name, function(client)
        vim.schedule(function()
            if sm._destroyed then
                return
            end
            sm.agent = client

            sm:new_session({
                restore_mode = true,
                quiet_welcome = true,
                on_created = function()
                    -- new_session built a fresh ChatHistory; swap back to the
                    -- saved one but keep the new session_id/timestamp.
                    local new_session_id = sm.chat_history.session_id
                    local new_timestamp = sm.chat_history.timestamp

                    sm.chat_history = saved_history
                    sm.chat_history.session_id = new_session_id
                    sm.chat_history.timestamp = new_timestamp

                    -- Prepend prior conversation on the next prompt submit so
                    -- the fresh provider-side session has context.
                    sm._history_to_send = saved_history.messages
                    sm._is_first_message = true
                end,
            })
        end)
    end)

    if not new_agent then
        return
    end
    sm.agent = new_agent
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
            M.cancel_retry_timer(sm, false)

            if sm._destroyed then
                return
            end

            if not sm.session_id then
                Logger.notify(
                    "No active session for auto-continue.",
                    vim.log.levels.WARN
                )
                return
            end

            local queued = sm._queued_prompts
            sm._queued_prompts = nil

            if queued then
                sm:_handle_input_submit(table.concat(queued, "\n\n"))
            else
                sm:_handle_input_submit("continue")
            end
        end)
    )
end

return M
