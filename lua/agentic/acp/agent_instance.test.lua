local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local MiniTest = require("mini.test")

describe("agentic.acp.AgentInstance", function()
    local AgentInstance = require("agentic.acp.agent_instance")
    local adapters = {
        ["opencode-acp"] = require("agentic.acp.adapters.opencode_acp_adapter"),
        ["gemini-acp"] = require("agentic.acp.adapters.gemini_acp_adapter"),
    }

    --- Stub of each adapter's `new`, keyed by provider name
    --- @type table<string, TestStub>
    local new_stubs

    before_each(function()
        new_stubs = {}
        for name, adapter in pairs(adapters) do
            new_stubs[name] = spy.stub(adapter, "new")
            new_stubs[name]:invokes(function()
                return {}
            end)
        end
    end)

    after_each(function()
        for _, stub in pairs(new_stubs) do
            stub:revert()
        end
        AgentInstance._instances = {}
    end)

    describe("get_instance", function()
        it("sets the provider name on the client", function()
            local client = AgentInstance.get_instance("opencode-acp")

            assert.equal("opencode-acp", client.provider_name)
        end)

        it("returns the same client for a second call", function()
            local first = AgentInstance.get_instance("opencode-acp")
            local second = AgentInstance.get_instance("opencode-acp")

            assert.equal(first, second)
            assert.spy(new_stubs["opencode-acp"]).was.called(1)
        end)

        it("gives two provider names two clients", function()
            local opencode = AgentInstance.get_instance("opencode-acp")
            local gemini = AgentInstance.get_instance("gemini-acp")

            assert.are_not.equal(opencode, gemini)
            assert.equal("gemini-acp", gemini.provider_name)
        end)

        describe("unattended", function()
            local Config = require("agentic.config")
            local Logger = require("agentic.utils.logger")
            local OpenCode = adapters["opencode-acp"]

            --- @type TestStub
            local env_stub
            --- @type TestStub
            local notify_stub

            before_each(function()
                env_stub = spy.stub(OpenCode, "unattended_env")
                env_stub:returns({ FOO = "1" })
                notify_stub = spy.stub(Logger, "notify")
            end)

            after_each(function()
                notify_stub:revert()
                env_stub:revert()
            end)

            it("gets its own client with the merged env", function()
                local provider = Config.acp_providers["opencode-acp"]
                local saved_env = provider.env
                provider.env = { BAR = "2" }
                MiniTest.finally(function()
                    provider.env = saved_env
                end)
                local before = vim.deepcopy(provider)
                local plain = AgentInstance.get_instance("opencode-acp")
                local unattended =
                    AgentInstance.get_instance("opencode-acp", nil, true)

                assert.is_false(rawequal(plain, unattended))
                assert.equal("opencode-acp", unattended.provider_name)
                assert.is_true(
                    rawequal(plain, AgentInstance.get_instance("opencode-acp"))
                )
                local config = new_stubs["opencode-acp"].calls[2][2]
                assert.same({ BAR = "2", FOO = "1" }, config.env)
                assert.same(before, provider)
            end)

            it("asks for the env once", function()
                local first =
                    AgentInstance.get_instance("opencode-acp", nil, true)
                local second =
                    AgentInstance.get_instance("opencode-acp", nil, true)

                assert.is_true(rawequal(first, second))
                assert.spy(env_stub).was.called(1)
            end)

            it("notifies and returns nil when the env fails", function()
                env_stub:invokes(function()
                    return nil, "bad OPENCODE_CONFIG_CONTENT"
                end)
                local on_ready = spy.new(function() end)

                local client =
                    AgentInstance.get_instance("opencode-acp", on_ready, true)

                assert.is_nil(client)
                assert.spy(on_ready).was.called(0)
                assert.spy(notify_stub).was.called(1)
                assert.spy(new_stubs["opencode-acp"]).was.called(0)
            end)
        end)

        describe("cached client", function()
            --- @param subscribers table
            --- @param state string|nil Default disconnected
            --- @return table client
            local function cached_client(subscribers, state)
                local client = {
                    state = state or "disconnected",
                    subscribers = subscribers,
                    restart = spy.new(function() end),
                    when_ready = spy.new(function() end),
                }
                new_stubs["opencode-acp"]:invokes(function()
                    return client
                end)
                AgentInstance.get_instance("opencode-acp")
                return client
            end

            it("restarts a dead one without subscribers", function()
                local client = cached_client({})
                local on_ready = spy.new(function() end)

                local returned =
                    AgentInstance.get_instance("opencode-acp", on_ready)

                assert.equal(client, returned)
                assert.spy(client.restart).was.called(1)
                assert.is_nil(client.restart.calls[1][2])
                assert.equal(on_ready, client.when_ready.calls[1][2])
                assert.spy(on_ready).was.called(0)
            end)

            it("restarts one in error", function()
                local client = cached_client({}, "error")

                AgentInstance.get_instance("opencode-acp")

                assert.spy(client.restart).was.called(1)
            end)

            for label, case in pairs({
                ["a dead one with subscribers"] = {
                    subscribers = { ["s-1"] = {} },
                },
                ["a live one in initializing"] = {
                    subscribers = {},
                    state = "initializing",
                },
            }) do
                it("hands " .. label .. " the callback to wait", function()
                    local client = cached_client(case.subscribers, case.state)
                    local on_ready = spy.new(function() end)

                    AgentInstance.get_instance("opencode-acp", on_ready)

                    assert.spy(client.restart).was.called(0)
                    assert.spy(on_ready).was.called(0)
                    assert.spy(client.when_ready).was.called(1)
                    assert.equal(on_ready, client.when_ready.calls[1][2])
                end)
            end
        end)
    end)

    describe("cleanup_all", function()
        it("stops each client's usage limit", function()
            for _, stub in pairs(new_stubs) do
                stub:invokes(function()
                    return {
                        usage_limit = { stop = spy.new(function() end) },
                        stop = function() end,
                    }
                end)
            end
            local clients = {
                AgentInstance.get_instance("opencode-acp"),
                AgentInstance.get_instance("gemini-acp"),
            }

            AgentInstance:cleanup_all()

            for _, client in ipairs(clients) do
                assert.spy(client.usage_limit.stop).was.called(1)
            end
        end)
    end)
end)
