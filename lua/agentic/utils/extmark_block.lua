local SIGNS = {
    HEADER = "╭─",
    BODY = "│ ",
    FOOTER = "╰─",
}

--- @class agentic.utils.ExtmarkBlock
local ExtmarkBlock = {}

ExtmarkBlock.SIGNS = SIGNS

--- @class agentic.utils.ExtmarkBlock.RenderBlockOpts
--- @field header_line integer 0-indexed line number for header
--- @field body_start? integer 0-indexed start line for body (optional)
--- @field body_end? integer 0-indexed end line for body (optional)
--- @field footer_line? integer 0-indexed line number for footer (optional)
--- @field hl_group string Highlight group name

--- Renders a complete block with sign column decorations
--- @param bufnr integer
--- @param ns_id integer
--- @param opts agentic.utils.ExtmarkBlock.RenderBlockOpts
--- @return integer[]
function ExtmarkBlock.render_block(bufnr, ns_id, opts)
    local decoration_ids = {}

    table.insert(
        decoration_ids,
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, opts.header_line, 0, {
            sign_text = SIGNS.HEADER,
            sign_hl_group = opts.hl_group,
        })
    )

    if opts.body_start and opts.body_end then
        for line_num = opts.body_start, opts.body_end do
            table.insert(
                decoration_ids,
                vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_num, 0, {
                    sign_text = SIGNS.BODY,
                    sign_hl_group = opts.hl_group,
                })
            )
        end
    end

    if opts.footer_line then
        table.insert(
            decoration_ids,
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, opts.footer_line, 0, {
                sign_text = SIGNS.FOOTER,
                sign_hl_group = opts.hl_group,
            })
        )
    end
    return decoration_ids
end

return ExtmarkBlock
