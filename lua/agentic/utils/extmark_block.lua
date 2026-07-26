-- Borders (╭─ │ ╰─) render via sign_text extmarks in the sign column rather
-- than inline virtual text. Signs survive nvim_buf_set_lines line-replacement
-- without delete/recreate cycles, so updates to a tool call block do not
-- displace its decorations.
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
--- @field ordinal? string 2-cell sign stamped in place of the │ border on every body row (subagent ordinal); nil leaves the plain border. The ╭─/╰─ corner rows keep their signs regardless. Concealed fence-delimiter rows receive it too but stay zero-height at conceallevel=2, so it does not show there

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
                    sign_text = opts.ordinal or SIGNS.BODY,
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

--- Rewrite one row's border sign in place, reusing the extmark id so no
--- duplicate sign is created. Used to backfill a subagent ordinal onto a block
--- rendered before concurrent-subagent numbering activated.
--- @param bufnr integer
--- @param ns_id integer
--- @param extmark_id integer Existing decoration extmark to overwrite
--- @param row integer 0-indexed buffer row
--- @param sign_text string 2-cell sign
--- @param hl_group string
function ExtmarkBlock.set_sign(bufnr, ns_id, extmark_id, row, sign_text, hl_group)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, 0, {
        id = extmark_id,
        sign_text = sign_text,
        sign_hl_group = hl_group,
    })
end

return ExtmarkBlock
