local assert = require("tests.helpers.assert")

local States = require("agentic.states")

describe("agentic.acp.SlashCommands", function()
    local SlashCommands = require("agentic.acp.slash_commands")

    --- @type integer
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- Helper: collect commands into a name→command map
    --- @param commands agentic.acp.SlashCommand[]
    --- @return table<string, agentic.acp.SlashCommand>
    local function by_name(commands)
        local map = {}
        for _, cmd in ipairs(commands) do
            map[cmd.word] = cmd
        end
        return map
    end

    describe("setCommands", function()
        it("sets commands from ACP provider and adds builtins", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
                { name = "review", description = "Review code" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()
            local map = by_name(commands)

            -- Provider commands present
            assert.equal("Create a plan", map["plan"].menu)
            assert.equal("Review code", map["review"].menu)

            -- Builtins injected
            assert.is_not_nil(map["new"])
            assert.is_not_nil(map["context"])
            assert.is_not_nil(map["clear"])
            assert.is_not_nil(map["rename"])

            -- Total: 2 provider + 4 builtins
            assert.equal(6, #commands)
        end)

        it("does not duplicate builtin if already provided", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "new", description = "Custom new description" },
                { name = "clear", description = "Custom clear" },
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()
            local map = by_name(commands)

            -- Provider descriptions win over builtins
            assert.equal("Custom new description", map["new"].menu)
            assert.equal("Custom clear", map["clear"].menu)

            -- No duplicates
            local new_count = 0
            local clear_count = 0
            for _, cmd in ipairs(commands) do
                if cmd.word == "new" then
                    new_count = new_count + 1
                end
                if cmd.word == "clear" then
                    clear_count = clear_count + 1
                end
            end
            assert.equal(1, new_count)
            assert.equal(1, clear_count)
        end)

        it("filters out commands with spaces in name", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "valid", description = "Valid command" },
                { name = "has space", description = "Invalid command" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()

            for _, cmd in ipairs(commands) do
                assert.is_false(cmd.word:match("%s") ~= nil)
            end
            -- valid + 4 builtins (context, new, clear, rename)
            assert.equal(5, #commands)
        end)

        it("skips commands with missing name or description", function()
            --- @type table[]
            local commands_mock = {
                { name = "valid", description = "Valid command" },
                { name = "no-desc" }, -- Missing description
                { description = "No name" }, -- Missing name
            }

            ---@diagnostic disable-next-line: param-type-mismatch
            SlashCommands.setCommands(bufnr, commands_mock)
            local commands = States.getSlashCommands()

            -- valid + 4 builtins (context, new, clear, rename)
            assert.equal(5, #commands)
        end)
    end)

    describe("instance management", function()
        it("allows independent commands per buffer instance", function()
            local bufnr2 = vim.api.nvim_create_buf(false, true)

            --- @type agentic.acp.AvailableCommand[]
            local commands1 = {
                { name = "plan", description = "Create a plan" },
            }

            --- @type agentic.acp.AvailableCommand[]
            local commands2 = {
                { name = "review", description = "Review code" },
            }

            SlashCommands.setCommands(bufnr, commands1)
            SlashCommands.setCommands(bufnr2, commands2)

            local commands_buf1 = States.getSlashCommands()
            vim.api.nvim_set_current_buf(bufnr2)
            local commands_buf2 = States.getSlashCommands()

            local map1 = by_name(commands_buf1)
            local map2 = by_name(commands_buf2)

            assert.is_not_nil(map1["plan"])
            assert.is_nil(map1["review"])
            assert.is_not_nil(map2["review"])
            assert.is_nil(map2["plan"])

            if vim.api.nvim_buf_is_valid(bufnr2) then
                vim.api.nvim_buf_delete(bufnr2, { force = true })
            end
        end)
    end)
end)
