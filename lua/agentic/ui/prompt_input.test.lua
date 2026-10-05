local assert = require("tests.helpers.assert")
local Config = require("agentic.config")
local PromptInput = require("agentic.ui.prompt_input")

describe("agentic.ui.PromptInput", function()
    local bufnr
    local original_submit

    before_each(function()
        original_submit = Config.keymaps.prompt.submit
        Config.keymaps.prompt.submit = "<F5>"
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].buftype = "acwrite"
        vim.api.nvim_buf_set_name(bufnr, "agentic-prompt-input-test")
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "draft", "/cmd" })
    end)

    after_each(function()
        Config.keymaps.prompt.submit = original_submit
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("the map submits unforced and :w forced, once after a rebind", function()
        local calls = {}
        local function submit(opts)
            table.insert(calls, opts.force)
        end
        PromptInput.bind_submit(bufnr, submit)
        PromptInput.bind_submit(bufnr, submit)

        vim.api.nvim_buf_call(bufnr, function()
            vim.fn.maparg("<F5>", "n", false, true).callback()
            vim.cmd.write()
        end)

        assert.same({ false, true }, calls)
    end)

    it("edits no buffer", function()
        local ns = vim.api.nvim_create_namespace("agentic_prompt_input_test")
        vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 0, { end_row = 1 })

        PromptInput.bind_submit(bufnr, function() end)

        assert.same(
            { "draft", "/cmd" },
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        )
        assert.equal(1, #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
    end)
end)
