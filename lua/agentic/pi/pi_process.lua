local AgentClient = require("agentic.agent_client")
local Logger = require("agentic.utils.logger")
local transport_module = require("agentic.acp.acp_transport")

--- @class agentic.pi.PiProcess.Opts
--- @field command string
--- @field args string[]
--- @field env table<string, string|nil>
--- @field cwd string
--- @field on_event fun(event: table) A session event
--- @field on_ui_request fun(request: table) An `extension_ui_request`
--- @field on_exit fun(code: integer|nil) The process ended; called once

--- One `pi --mode rpc` process and its RPC framing: commands on stdin, a
--- `response` per command matched by `id`, events on stdout. Every callback
--- runs on the main loop, in the order the records arrived.
--- See https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md
--- @class agentic.pi.PiProcess
--- @field _transport agentic.acp.ACPTransportInstance
--- @field _pending table<string, fun(data: table|nil, err: agentic.AgentClient.Error|nil)>
--- @field _next_id integer
--- @field _exited boolean
--- @field _exit_waiters fun(code: integer|nil)[]
local PiProcess = {}
PiProcess.__index = PiProcess

--- How long a process may take to exit after its stdin closes.
local STOP_GRACE_MS = 3000

--- Start the process.
--- @param opts agentic.pi.PiProcess.Opts
--- @return agentic.pi.PiProcess
function PiProcess:new(opts)
    local process = setmetatable({
        _pending = {},
        _next_id = 0,
        _exited = false,
        _exit_waiters = { opts.on_exit },
    }, self) --[[@as agentic.pi.PiProcess]]
    process:_start(opts)
    return process
end

--- Spawn the process. A failure to spawn counts as its exit.
--- @param opts agentic.pi.PiProcess.Opts
function PiProcess:_start(opts)
    self._transport = transport_module.create_stdio_transport({
        command = opts.command,
        args = opts.args,
        env = opts.env,
        cwd = opts.cwd,
    }, {
        on_state_change = function(state)
            if state == "disconnected" then
                vim.schedule(function()
                    self:_on_exit()
                end)
            end
        end,
        on_message = function(message)
            vim.schedule(function()
                self:_on_record(message, opts)
            end)
        end,
        on_reconnect = function() end,
        on_stdout_line = function(line)
            Logger.debug("pi stdout: " .. line)
        end,
        on_stderr_line = function(line)
            Logger.debug("pi stderr: " .. line)
        end,
    })

    local ok, err = pcall(self._transport.start, self._transport)
    if not ok then
        Logger.notify(
            "Failed to start pi: " .. tostring(err),
            vim.log.levels.ERROR
        )
        vim.schedule(function()
            self:_on_exit()
        end)
    end
end

--- Dispatch one stdout record: a `response` to its request's callback, an
--- `extension_ui_request` to `opts.on_ui_request`, any other record to
--- `opts.on_event`.
--- @param record table
--- @param opts agentic.pi.PiProcess.Opts
function PiProcess:_on_record(record, opts)
    if record.type == "response" then
        local callback = record.id and self._pending[record.id]
        if not callback then
            Logger.debug("pi response to no request: " .. vim.inspect(record))
            return
        end
        self._pending[record.id] = nil
        if record.success then
            callback(record.data or {}, nil)
        else
            callback(nil, {
                code = AgentClient.ERROR_CODES.INTERNAL_ERROR,
                message = record.error
                    or ("pi rejected " .. tostring(record.command)),
            })
        end
    elseif record.type == "extension_ui_request" then
        opts.on_ui_request(record)
    else
        opts.on_event(record)
    end
end

--- Fail the pending requests with `TRANSPORT_ERROR` and run the exit
--- waiters. Runs once per process.
function PiProcess:_on_exit()
    if self._exited then
        return
    end
    self._exited = true
    -- Closes the pipes; its own `disconnected` finds `_exited` set.
    self._transport:stop()
    local pending = self._pending
    self._pending = {}
    for _, callback in pairs(pending) do
        callback(nil, {
            code = AgentClient.ERROR_CODES.TRANSPORT_ERROR,
            message = "pi exited",
        })
    end
    for _, waiter in ipairs(self._exit_waiters) do
        waiter(nil)
    end
    self._exit_waiters = {}
end

--- Send a command and match its `response`.
--- @param command table An RPC command without `id`
--- @param callback fun(data: table|nil, err: agentic.AgentClient.Error|nil) Gets the response's `data` (`{}` when it has none), or `INTERNAL_ERROR` with pi's `error` when it failed, `TRANSPORT_ERROR` when the process exits first
function PiProcess:request(command, callback)
    self._next_id = self._next_id + 1
    local id = "agentic-" .. self._next_id
    local record = vim.tbl_extend("force", command, { id = id })
    if self._exited or not self._transport:send(vim.json.encode(record)) then
        vim.schedule(function()
            callback(nil, {
                code = AgentClient.ERROR_CODES.TRANSPORT_ERROR,
                message = "pi is not running",
            })
        end)
        return
    end
    self._pending[id] = callback
end

--- Answer an extension dialog.
--- @param id string The `extension_ui_request`'s id
--- @param response table `{ value }`, `{ confirmed }` or `{ cancelled = true }`
function PiProcess:respond_ui(id, response)
    local record = vim.tbl_extend(
        "force",
        response,
        { type = "extension_ui_response", id = id }
    )
    self._transport:send(vim.json.encode(record))
end

--- Ask the process to shut down by closing its stdin, and kill it when it
--- has not exited after a grace period.
--- @param on_exit fun()|nil Runs once the process has exited
function PiProcess:stop(on_exit)
    if on_exit then
        if self._exited then
            vim.schedule(on_exit)
        else
            table.insert(self._exit_waiters, on_exit)
        end
    end
    if self._exited then
        return
    end
    local stdin = self._transport.stdin
    if stdin and not stdin:is_closing() then
        stdin:close()
    end
    self._transport.stdin = nil
    vim.defer_fn(function()
        if not self._exited then
            self._transport:stop()
        end
    end, STOP_GRACE_MS)
end

return PiProcess
