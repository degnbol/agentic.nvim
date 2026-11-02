local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local ChatBuffer = require("agentic.ui.chat_buffer")
local Treesitter = require("agentic.utils.treesitter")

describe("agentic.ui.ChatBuffer", function()
    describe("win_opts", function()
        local original_windows

        before_each(function()
            original_windows = vim.deepcopy(Config.windows)
        end)

        after_each(function()
            Config.windows = original_windows
        end)

        it("soft-wraps only when wrap_width is 0", function()
            Config.windows.wrap_width = 0
            assert.is_true(ChatBuffer.win_opts().wrap)

            Config.windows.wrap_width = 80
            assert.is_false(ChatBuffer.win_opts().wrap)
        end)
    end)

    describe("conceallevel", function()
        local original_windows
        local bufnr

        before_each(function()
            original_windows = vim.deepcopy(Config.windows)
            bufnr = vim.api.nvim_create_buf(false, true)
            vim.b[bufnr].agentic_window = "agent"
        end)

        after_each(function()
            Config.windows = original_windows
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("reads the window that shows the buffer", function()
            local winid = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 0,
                col = 0,
                width = 10,
                height = 1,
            })
            vim.wo[winid].conceallevel = 3
            assert.equal(3, ChatBuffer.conceallevel(bufnr))
        end)

        it("is the chat default without a window", function()
            assert.equal(
                ChatBuffer.win_opts().conceallevel,
                ChatBuffer.conceallevel(bufnr)
            )
        end)

        it("is the user's win_opts value without a window", function()
            Config.windows.agent.win_opts = { conceallevel = 1 }
            assert.equal(1, ChatBuffer.conceallevel(bufnr))
        end)
    end)

    describe("cell_measure", function()
        it("measures a cell once and returns the same width again", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local width_spy = spy.on(Treesitter, "concealed_width")
            local measure = ChatBuffer.cell_measure(bufnr)
            local first = measure("**a** b")
            assert.equal(first, measure("**a** b"))
            assert.equal(1, width_spy.call_count)
            width_spy:revert()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("keeps the level it was made at", function()
            local original_windows = vim.deepcopy(Config.windows)
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.b[bufnr].agentic_window = "agent"
            Config.windows.agent.win_opts = { conceallevel = 0 }
            local measure = ChatBuffer.cell_measure(bufnr)
            Config.windows.agent.win_opts = { conceallevel = 2 }
            assert.equal(8, measure("**bold**"))
            Config.windows = original_windows
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)
end)
