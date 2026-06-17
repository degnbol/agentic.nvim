local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.AgentModels", function()
    --- @type agentic.acp.AgentModels
    local AgentModels

    --- @type agentic.acp.AgentModels
    local agent_models

    --- @type agentic.acp.ModelsInfo
    local models_info = {
        availableModels = {
            {
                modelId = "default",
                name = "Default (recommended)",
                description = "Default model",
            },
            { modelId = "opus", name = "Opus", description = "Most capable" },
            {
                modelId = "sonnet",
                name = "Sonnet",
                description = "Fast and smart",
            },
        },
        currentModelId = "default",
    }

    before_each(function()
        AgentModels = require("agentic.acp.agent_models")
        agent_models = AgentModels:new()
        agent_models:set_models(models_info)
    end)

    describe("get_model", function()
        it("returns model with matching modelId", function()
            local result = agent_models:get_model("opus")

            assert.is_not_nil(result)
            if result ~= nil then
                assert.equal("opus", result.modelId)
                assert.equal("Opus", result.name)
            end
        end)

        it("returns nil for non-existent or empty models", function()
            assert.is_nil(agent_models:get_model("nonexistent"))

            agent_models:set_models({
                availableModels = {},
                currentModelId = "",
            })
            assert.is_nil(agent_models:get_model("any_id"))
        end)
    end)

    describe("show_model_selector", function()
        --- @type TestStub
        local select_stub

        before_each(function()
            select_stub = spy.stub(vim.ui, "select")
        end)

        after_each(function()
            select_stub:revert()
        end)

        it("returns false when models list is empty", function()
            agent_models:set_models({
                availableModels = {},
                currentModelId = "",
            })

            local shown = agent_models:show_model_selector(function() end)

            assert.is_false(shown)
            assert.stub(select_stub).was.called(0)
        end)

        it("calls callback with selected model id", function()
            local callback_spy = spy.new(function() end)
            select_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[2])
            end)

            agent_models:show_model_selector(
                callback_spy --[[@as fun(model_id: string)]]
            )

            assert.spy(callback_spy).was.called_with("opus")
        end)

        it("does not call callback on current model or cancel", function()
            local callback_spy = spy.new(function() end)

            select_stub:invokes(function(items, _opts, on_choice)
                on_choice(items[1])
            end)
            agent_models:show_model_selector(
                callback_spy --[[@as fun(model_id: string)]]
            )

            select_stub:invokes(function(_items, _opts, on_choice)
                on_choice(nil)
            end)
            agent_models:show_model_selector(
                callback_spy --[[@as fun(model_id: string)]]
            )

            assert.spy(callback_spy).was.called(0)
        end)
    end)

    describe("clear", function()
        it("resets models and current_model_id", function()
            agent_models:clear()

            assert.is_nil(agent_models:get_model("default"))
            assert.is_nil(agent_models:get_model("opus"))
            assert.is_nil(agent_models.current_model_id)
        end)
    end)
end)
