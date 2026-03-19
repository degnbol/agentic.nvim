-- Dim ```markdown fenced code blocks (fetch/WebSearch output) by linking them
-- to Comment at priority 101 (above injection highlights at 100). Only targets
-- blocks with `markdown` info string — zsh/console/other fences are unaffected.
--
-- vim.treesitter.query.set is global (per-language, not per-buffer), but this
-- only activates once an AgenticChat buffer is created.
if not vim.g._agentic_md_highlights_set then
    vim.g._agentic_md_highlights_set = true

    vim.api.nvim_set_hl(
        0,
        "@AgenticDimmedBlock",
        { link = "Comment", default = true }
    )

    -- Query objects don't expose source text, so read the files from rtp
    local files =
        vim.api.nvim_get_runtime_file("queries/markdown/highlights.scm", true)
    local parts = {}
    for _, file in ipairs(files) do
        local lines = vim.fn.readfile(file)
        local filtered = {}
        for _, line in ipairs(lines) do
            if not line:match("^;%s*extends") then
                table.insert(filtered, line)
            end
        end
        table.insert(parts, table.concat(filtered, "\n"))
    end

    -- Only dim fenced code blocks whose info_string language is "markdown"
    table.insert(
        parts,
        table.concat({
            "((fenced_code_block",
            "  (info_string (language) @_lang)",
            '  (#eq? @_lang "markdown")) @AgenticDimmedBlock',
            "(#set! priority 101))",
        }, "\n")
    )

    pcall(
        vim.treesitter.query.set,
        "markdown",
        "highlights",
        table.concat(parts, "\n")
    )
end
