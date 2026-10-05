local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")

--- Submit bindings shared by the buffers a prompt is typed into.
--- @class agentic.ui.PromptInput
local PromptInput = {}

local GROUP = vim.api.nvim_create_augroup("agentic_prompt_submit", {})

--- @class agentic.ui.PromptInput.SubmitOpts
--- @field force boolean Send now even if the session would defer the prompt

--- Bind `keymaps.prompt.submit` on `bufnr` to `submit` with `force = false`
--- and, with `settings.write_submit`, `:w` to it with `force = true`. Binding
--- again replaces the earlier binding. Edits no buffer.
--- @param bufnr integer
--- @param submit fun(opts: agentic.ui.PromptInput.SubmitOpts)
function PromptInput.bind_submit(bufnr, submit)
    if not BufHelpers.is_keymap_disabled(Config.keymaps.prompt.submit) then
        BufHelpers.multi_keymap_set(
            Config.keymaps.prompt.submit,
            bufnr,
            function()
                submit({ force = false })
            end,
            { desc = "Agentic: Submit prompt" }
        )
    end

    vim.api.nvim_clear_autocmds({ group = GROUP, buffer = bufnr })
    if not Config.settings.write_submit then
        return
    end
    -- The write commands are the deliberate escape hatch: send now regardless
    -- of what the session would otherwise defer for. Submitted during the
    -- write: vim fails a write whose BufWriteCmd leaves the buffer modified,
    -- and `:wq`/`:x` then stop short of closing the window.
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = GROUP,
        buffer = bufnr,
        callback = function()
            submit({ force = true })
        end,
    })
end

return PromptInput
