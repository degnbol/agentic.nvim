local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

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
