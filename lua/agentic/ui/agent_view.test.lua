local assert = require("tests.helpers.assert")
local AgentConfigOptions = require("agentic.acp.agent_config_options")
local AgentView = require("agentic.ui.agent_view")
local ChatBuffer = require("agentic.ui.chat_buffer")

describe("agentic.ui.AgentView", function()
    --- @type integer
    local bufnr
    --- @type agentic.ui.AgentView
    local view

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        ChatBuffer.setup(bufnr)
        view = AgentView:new(bufnr)
    end)

    after_each(function()
        view.status_indicator:stop()
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    --- @return string[]
    local function lines()
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    --- Options offering `models`, running `current` at an `Effort: High`
    --- thought level.
    --- @param models agentic.acp.ConfigOption.Option[]
    --- @param current string|nil
    --- @return agentic.acp.AgentConfigOptions
    local function offering(models, current)
        local noop = function() end
        local options = AgentConfigOptions:new(noop, noop, noop, function()
            return true
        end)
        options:set_options({
            {
                id = "model",
                category = "model",
                currentValue = current or "",
                description = "",
                name = "Model",
                options = models,
            },
            {
                id = "effort",
                category = "thought_level",
                currentValue = "high",
                description = "",
                name = "Effort",
                options = { { value = "high", name = "High" } },
            },
        })
        return options
    end

    describe("announce_model", function()
        it("writes bold name · id and the description", function()
            local options = offering({
                { value = "m", name = "M", description = "M's description" },
            })

            view:announce_model(options, "m")

            assert.truthy(vim.tbl_contains(lines(), "**Loaded M** · m"))
            assert.truthy(vim.tbl_contains(lines(), "M's description"))
        end)

        it("adds the thought level of the current model", function()
            local options =
                offering({ { value = "m", name = "M", description = "" } }, "m")

            view:announce_model(options, "m")

            assert.truthy(
                vim.tbl_contains(lines(), "**Loaded M** · m · Effort: High")
            )
        end)

        it("writes nothing for a nil model", function()
            local before = lines()

            view:announce_model(offering({}), nil)

            assert.same(before, lines())
        end)
    end)
end)
