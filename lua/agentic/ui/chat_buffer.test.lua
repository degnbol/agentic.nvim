local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local MiniTest = require("mini.test")
local AfterDraw = require("agentic.utils.after_draw")
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

    describe("defer_conceal", function()
        local bufnr
        local winid
        --- @type TestStub
        local once_stub
        --- @type fun()[]
        local after_draw

        before_each(function()
            after_draw = {}
            once_stub = spy.stub(AfterDraw, "once")
            once_stub:invokes(function(_, fn)
                table.insert(after_draw, fn)
            end)
            bufnr = vim.api.nvim_create_buf(false, true)
            winid = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 0,
                col = 0,
                width = 10,
                height = 2,
            })
            vim.wo[winid].conceallevel = 3
        end)

        after_each(function()
            once_stub:revert()
            if vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_win_close(winid, true)
            end
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        local function draw()
            for _, fn in ipairs(after_draw) do
                fn()
            end
            after_draw = {}
        end

        it("sets level 0 and restores the level after a draw", function()
            local restored = spy.new(function() end)
            ChatBuffer.defer_conceal(winid, restored --[[@as fun()]])
            assert.equal(0, vim.wo[winid].conceallevel)
            assert.equal(0, restored.call_count)

            draw()

            assert.equal(3, vim.wo[winid].conceallevel)
            assert.equal(1, restored.call_count)
            assert.is_nil(vim.w[winid].agentic_conceallevel)
        end)

        it("does nothing at levels 0 and 1", function()
            for _, level in ipairs({ 0, 1 }) do
                vim.wo[winid].conceallevel = level
                ChatBuffer.defer_conceal(winid, function() end)
                assert.equal(level, vim.wo[winid].conceallevel)
            end
            assert.equal(0, once_stub.call_count)
        end)

        it("does nothing while a deferral waits", function()
            ChatBuffer.defer_conceal(winid, function() end)
            ChatBuffer.defer_conceal(winid, function() end)

            assert.equal(1, once_stub.call_count)
            draw()
            assert.equal(3, vim.wo[winid].conceallevel)
        end)

        it("leaves a window that shows another buffer by then", function()
            local restored = spy.new(function() end)
            ChatBuffer.defer_conceal(winid, restored --[[@as fun()]])
            local other = vim.api.nvim_create_buf(false, true)
            MiniTest.finally(function()
                vim.api.nvim_buf_delete(other, { force = true })
            end)
            vim.api.nvim_win_set_buf(winid, other)
            vim.wo[winid].conceallevel = 0

            draw()

            assert.equal(0, vim.wo[winid].conceallevel)
            assert.equal(0, restored.call_count)
            assert.is_nil(vim.w[winid].agentic_conceallevel)
        end)

        it("conceallevel reads the saved level during a deferral", function()
            ChatBuffer.defer_conceal(winid, function() end)

            assert.equal(3, ChatBuffer.conceallevel(bufnr))
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
