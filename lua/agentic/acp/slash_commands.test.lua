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

    describe("setCommands", function()
        it(
            "sets commands from ACP provider and automatically adds /new",
            function()
                --- @type agentic.acp.AvailableCommand[]
                local commands_mock = {
                    { name = "plan", description = "Create a plan" },
                    { name = "review", description = "Review code" },
                }

                SlashCommands.setCommands(bufnr, commands_mock)

                local commands = States.getSlashCommands()

                -- Verify total count includes /new
                assert.equal(3, #commands)

                -- Verify provided commands are set correctly
                assert.equal("plan", commands[1].word)
                assert.equal("Create a plan", commands[1].menu)
                assert.equal("Create a plan", commands[1].info)
                assert.equal("review", commands[2].word)
                assert.equal("Review code", commands[2].menu)
                assert.equal("Review code", commands[2].info)

                -- Verify /new was automatically added at the end
                assert.equal("new", commands[3].word)
                assert.equal("Start a new session", commands[3].menu)
                assert.equal("Start a new session", commands[3].info)
            end
        )

        it("does not duplicate /new command if already provided", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "new", description = "Custom new description" },
                { name = "plan", description = "Create a plan" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()

            assert.equal(2, #commands)

            local new_count = 0
            for _, cmd in ipairs(commands) do
                if cmd.word == "new" then
                    new_count = new_count + 1
                    assert.equal("Custom new description", cmd.menu)
                    assert.equal("Custom new description", cmd.info)
                end
            end
            assert.equal(1, new_count)
        end)

        it("filters out commands with spaces in name", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "valid", description = "Valid command" },
                { name = "has space", description = "Invalid command" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)

            local commands = States.getSlashCommands()

            assert.equal(2, #commands) -- valid + /new
            for _, cmd in ipairs(commands) do
                assert.is_false(cmd.word:match("%s") ~= nil)
            end
        end)

        it("includes all valid commands from the provider", function()
            --- @type agentic.acp.AvailableCommand[]
            local commands_mock = {
                { name = "plan", description = "Create a plan" },
                { name = "clear", description = "Clear session" },
            }

            SlashCommands.setCommands(bufnr, commands_mock)
            local commands = States.getSlashCommands()

            assert.equal(3, #commands) -- plan + clear + /new
            local names = {}
            for _, cmd in ipairs(commands) do
                names[cmd.word] = true
            end
            assert.is_true(names["clear"])
            assert.is_true(names["plan"])
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

            assert.equal(2, #commands) -- valid + /new
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

            assert.equal(2, #commands_buf1) -- plan + /new
            assert.equal(2, #commands_buf2) -- review + /new
            assert.equal("plan", commands_buf1[1].word)
            assert.equal("review", commands_buf2[1].word)

            if vim.api.nvim_buf_is_valid(bufnr2) then
                vim.api.nvim_buf_delete(bufnr2, { force = true })
            end
        end)
    end)
end)
