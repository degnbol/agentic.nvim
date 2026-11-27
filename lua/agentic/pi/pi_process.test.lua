--- @diagnostic disable: invisible, missing-fields
local assert = require("tests.helpers.assert")
local deferred_helper = require("tests.helpers.deferred")
local spy = require("tests.helpers.spy")

describe("agentic.pi.PiProcess", function()
    local AgentClient = require("agentic.agent_client")
    local PiProcess = require("agentic.pi.pi_process")
    local transport_module = require("agentic.acp.acp_transport")

    --- A transport that records what is sent and lets the test deliver.
    --- @class tests.FakePiTransport
    --- @field callbacks table
    --- @field sent table[] Decoded records, in order
    --- @field stops integer
    --- @field start fun(self: tests.FakePiTransport)
    --- @field send fun(self: tests.FakePiTransport, data: string): boolean
    --- @field stop fun(self: tests.FakePiTransport)
    --- @field stdin { closed: boolean, is_closing: fun(self): boolean, close: fun(self) }|nil

    --- @type tests.FakePiTransport
    local transport
    --- @type tests.helpers.Deferred
    local deferred
    --- @type TestStub
    local create_stub
    --- @type TestStub
    local defer_stub
    --- @type TestStub
    local notify_stub
    --- @type fun()[]
    local timers

    before_each(function()
        deferred = deferred_helper.capture()
        timers = {}
        create_stub = spy.stub(transport_module, "create_stdio_transport")
        create_stub:invokes(function(_config, callbacks)
            transport = {
                callbacks = callbacks,
                sent = {},
                stops = 0,
                stdin = {
                    closed = false,
                    is_closing = function(self)
                        return self.closed
                    end,
                    close = function(self)
                        self.closed = true
                    end,
                },
            }
            function transport:start() end
            function transport:send(data)
                table.insert(self.sent, vim.json.decode(data))
                return true
            end
            function transport:stop()
                self.stops = self.stops + 1
            end
            return transport
        end)
        defer_stub = spy.stub(vim, "defer_fn")
        defer_stub:invokes(function(fn)
            table.insert(timers, fn)
        end)
        notify_stub = spy.stub(require("agentic.utils.logger"), "notify")
    end)

    after_each(function()
        notify_stub:revert()
        defer_stub:revert()
        create_stub:revert()
        deferred.revert()
    end)

    --- @param overrides table|nil
    --- @return agentic.pi.PiProcess process
    --- @return table log What the callbacks got, in order
    local function start(overrides)
        local log = {}
        local opts = vim.tbl_extend("force", {
            command = "pi",
            args = {},
            env = {},
            cwd = "/w",
            on_event = function(event)
                table.insert(log, { "event", event })
            end,
            on_ui_request = function(request)
                table.insert(log, { "ui", request })
            end,
            on_exit = function()
                table.insert(log, { "exit" })
            end,
        }, overrides or {})
        return PiProcess:new(opts), log
    end

    --- Deliver a record from the process.
    --- @param record table
    local function deliver(record)
        transport.callbacks.on_message(record)
        deferred.drain()
    end

    it("matches a response to its request by id", function()
        local process = start()
        local got = {}
        process:request({ type = "get_state" }, function(data, err)
            table.insert(got, { data, err })
        end)
        process:request({ type = "abort" }, function(data, err)
            table.insert(got, { data, err })
        end)
        assert.equal("agentic-1", transport.sent[1].id)
        assert.equal("get_state", transport.sent[1].type)
        deliver({
            type = "response",
            id = "agentic-2",
            command = "abort",
            success = false,
            error = "busy",
        })
        deliver({
            type = "response",
            id = "agentic-1",
            command = "get_state",
            success = true,
            data = { sessionId = "s1" },
        })
        assert.equal(2, #got)
        assert.equal("busy", got[1][2].message)
        assert.equal(AgentClient.ERROR_CODES.INTERNAL_ERROR, got[1][2].code)
        assert.same({ sessionId = "s1" }, got[2][1])
    end)

    it("routes events and extension UI requests", function()
        local _, log = start()
        deliver({ type = "agent_start" })
        deliver({ type = "extension_ui_request", id = "u1", method = "select" })
        assert.equal("event", log[1][1])
        assert.equal("ui", log[2][1])
    end)

    it("fails pending requests and calls the exit waiters once", function()
        local process, log = start()
        local err
        process:request({ type = "get_state" }, function(_, e)
            err = e
        end)
        local stopped = false
        process:stop(function()
            stopped = true
        end)
        transport.callbacks.on_state_change("disconnected")
        transport.callbacks.on_state_change("disconnected")
        deferred.drain()
        assert.equal(AgentClient.ERROR_CODES.TRANSPORT_ERROR, err.code)
        assert.equal(1, #vim.tbl_filter(function(e)
            return e[1] == "exit"
        end, log))
        assert.is_true(stopped)
    end)

    it("closes stdin to stop, and kills after the grace period", function()
        local process = start()
        local stdin = transport.stdin --[[@as table]]
        process:stop()
        assert.is_true(stdin.closed)
        assert.equal(0, transport.stops)
        timers[1]()
        assert.equal(1, transport.stops)
    end)

    it(
        "kills nothing after the grace period once the process exited",
        function()
            local process = start()
            process:stop()
            transport.callbacks.on_state_change("disconnected")
            deferred.drain()
            local stops = transport.stops
            timers[1]()
            assert.equal(stops, transport.stops)
        end
    )

    it("counts a spawn failure as the exit", function()
        create_stub:invokes(function(_config, callbacks)
            transport = {
                callbacks = callbacks,
                sent = {},
                stops = 0,
            }
            function transport:start()
                error("ENOENT")
            end
            function transport:stop()
                self.stops = self.stops + 1
            end
            return transport
        end)
        local process, log = start()
        deferred.drain()
        assert.same({ { "exit" } }, log)
        local err
        process:request({ type = "get_state" }, function(_, e)
            err = e
        end)
        deferred.drain()
        assert.equal(AgentClient.ERROR_CODES.TRANSPORT_ERROR, err.code)
    end)
end)
