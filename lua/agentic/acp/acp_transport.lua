local LineReader = require("agentic.utils.line_reader")
local Logger = require("agentic.utils.logger")

--- @alias agentic.acp.TransportType "stdio" | "tcp" | "websocket"

--- @class agentic.acp.ACPTransportModule
local M = {}

--- @class agentic.acp.TransportCallbacks
--- @field on_state_change fun(state: agentic.acp.ClientConnectionState): nil The transport state like "connecting", "connected", "disconnected", "error"
--- @field on_message fun(message: agentic.acp.ResponseRaw): nil
--- @field on_reconnect fun(): nil
--- @field on_stdout_line fun(line: string): nil A non-blank stdout line that is not JSON, untrimmed. Called in the luv read callback.
--- @field on_stderr_line fun(line: string): nil A non-blank stderr line, untrimmed. Called in the luv read callback.

--- @class agentic.acp.StdioTransportConfig
--- @field command string Command to spawn agent
--- @field args? string[] Arguments for agent command
--- @field env? table<string, string|nil> Environment variables
--- @field enable_reconnect? boolean Enable auto-reconnect
--- @field max_reconnect_attempts? number Maximum reconnection attempts

--- Create stdio transport for ACP communication
--- @param config agentic.acp.StdioTransportConfig
--- @param callbacks agentic.acp.TransportCallbacks
--- @return agentic.acp.ACPTransportInstance
function M.create_stdio_transport(config, callbacks)
    local reconnect_count = 0

    --- @class agentic.acp.ACPTransportInstance
    local transport = {
        --- @type uv.uv_pipe_t|nil
        stdin = nil,
        --- @type uv.uv_pipe_t|nil
        stdout = nil,
        --- @type uv.uv_process_t|nil
        process = nil,
    }

    --- @param data string
    function transport:send(data)
        if self.stdin and not self.stdin:is_closing() then
            self.stdin:write(data .. "\n")
            return true
        end
        return false
    end

    function transport:start()
        callbacks.on_state_change("connecting")

        local stdin = vim.uv.new_pipe(false)
        local stdout = vim.uv.new_pipe(false)
        local stderr = vim.uv.new_pipe(false)

        if not stdin or not stdout or not stderr then
            callbacks.on_state_change("error")
            error("Failed to create pipes for ACP agent")
        end

        -- Capture stderr for better error reporting
        local stderr_buffer = {}
        local feed_stderr = LineReader.new(function(line)
            if vim.trim(line) == "" then
                return
            end
            table.insert(stderr_buffer, line)
            callbacks.on_stderr_line(line)
        end)
        local args = vim.deepcopy(config.args or {})
        local env = config.env

        -- Inherit full parent environment to support Nix, AWS Bedrock, proxies, custom CA bundles, etc.
        -- uv.spawn replaces the entire environment, so we must explicitly include everything
        local env_map = {}
        for k, v in pairs(vim.fn.environ()) do
            env_map[k] = v
        end

        -- Add default variables for ACP providers (overwrites parent if present)
        env_map["NODE_NO_WARNINGS"] = "1"
        env_map["IS_AI_TERMINAL"] = "1"

        -- Socket this nvim listens on, so a PreToolUse hook (grandchild of the
        -- bridge) can RPC back into the live editor to run the permission
        -- ladder. Propagates nvim -> bridge -> SDK CLI -> hook via the
        -- inherited environment. See permission_hook.lua.
        env_map["AGENTIC_SOCK"] = vim.v.servername ~= "" and vim.v.servername
            or vim.fn.serverstart()

        -- Apply user-provided env overrides/additions (overwrites defaults)
        if env then
            for k, v in pairs(env) do
                env_map[k] = v
            end
        end

        -- Serialize map to array format expected by libuv
        local final_env = {}
        for k, v in pairs(env_map) do
            table.insert(final_env, k .. "=" .. v)
        end

        --- @diagnostic disable-next-line: missing-fields
        local handle, pid = vim.uv.spawn(config.command, {
            args = args,
            env = final_env,
            stdio = { stdin, stdout, stderr },
            detached = false,
        }, function(code, signal)
            -- The pipe's EOF can arrive after exit; the report needs a last
            -- line written without a newline.
            feed_stderr(nil)

            local cmd_str = config.command
                .. (#args > 0 and " " .. table.concat(args, " ") or "")

            local exit_info = {
                "ACP agent exited:",
                "  Command: " .. cmd_str,
                "  Exit code: " .. tostring(code),
                "  Signal: " .. tostring(signal),
            }

            if code ~= 0 and #stderr_buffer > 0 then
                table.insert(exit_info, "  Stderr output:")
                for _, line in ipairs(stderr_buffer) do
                    table.insert(exit_info, "    " .. line)
                end
            end

            Logger.debug(table.concat(exit_info, "\n"))

            if code ~= 0 then
                local error_msg = string.format(
                    "ACP agent '%s' failed (exit code %d)",
                    config.command,
                    code
                )

                if #stderr_buffer > 0 then
                    error_msg = error_msg
                        .. ":\n"
                        .. table.concat(stderr_buffer, "\n")
                end
                Logger.notify(error_msg, vim.log.levels.ERROR)
            end

            callbacks.on_state_change("disconnected")

            if self.process then
                self.process:close()
                self.process = nil
            end

            -- Handle reconnection if enabled
            if config.enable_reconnect then
                local max_attempts = config.max_reconnect_attempts or 3

                if reconnect_count < max_attempts then
                    reconnect_count = reconnect_count + 1

                    vim.defer_fn(function()
                        callbacks.on_reconnect()
                    end, 2000)
                end
            end
        end)

        Logger.debug("Spawned ACP agent process with PID ", tostring(pid))

        if not handle then
            callbacks.on_state_change("error")
            error("Failed to spawn ACP agent process")
        end

        self.process = handle
        self.stdin = stdin
        self.stdout = stdout

        callbacks.on_state_change("connected")

        local feed_stdout = LineReader.new(function(line)
            local trimmed = vim.trim(line)
            if trimmed == "" then
                return
            end
            -- A decode error means the line is not JSON.
            local ok, message = pcall(vim.json.decode, trimmed)
            if ok then
                callbacks.on_message(message)
            else
                callbacks.on_stdout_line(line)
            end
        end)

        stdout:read_start(function(err, data)
            if err then
                Logger.notify("ACP stdout error: " .. err, vim.log.levels.ERROR)
                callbacks.on_state_change("error")
                return
            end
            feed_stdout(data)
        end)

        stderr:read_start(function(_, data)
            feed_stderr(data)
        end)
    end

    function transport:stop()
        if self.process and not self.process:is_closing() then
            local process = self.process --[[@as uv.uv_process_t]]
            self.process = nil

            -- Try to terminate gracefully
            pcall(function()
                process:kill(15)
            end)
            -- then force kill, it'll fail harmlessly if already exited
            pcall(function()
                process:kill(9)
            end)

            process:close()
        end

        if self.stdin then
            self.stdin:close()
            self.stdin = nil
        end

        if self.stdout then
            self.stdout:close()
            self.stdout = nil
        end

        callbacks.on_state_change("disconnected")
    end

    return transport
end

return M
