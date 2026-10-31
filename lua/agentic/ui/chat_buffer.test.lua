local assert = require("tests.helpers.assert")
local Config = require("agentic.config")
local ChatBuffer = require("agentic.ui.chat_buffer")

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
end)
