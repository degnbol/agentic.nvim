-- A region's signs render via sign_text extmarks in the sign column rather than
-- inline virtual text. They stay put only where a region is updated in place —
-- nvim_buf_set_text, which is all a tool call block's status footer refresh
-- runs. A line replacement (nvim_buf_set_lines) displaces every sign it spans,
-- collapsing them onto the replacement's first row, so a caller that replaces
-- lines re-stamps the region rather than expecting its signs to survive.
--
-- The opening row carries the region's identity (a per-kind glyph, a prompt's
-- `❯`), continuation rows `│`, the last row `╰─`. The caller supplies the
-- identity sign; only the rail below it belongs to this module's vocabulary.
local SIGNS = {
    -- Opener for a region with no identity to announce (prose).
    HEADER = "╭─",
    BODY = "│ ",
    FOOTER = "╰─",
}

--- @class agentic.utils.ExtmarkBlock
local ExtmarkBlock = {}

ExtmarkBlock.SIGNS = SIGNS

--- @class agentic.utils.ExtmarkBlock.RenderRailOpts
--- @field body_start? integer 0-indexed first continuation line (optional)
--- @field body_end? integer 0-indexed last continuation line, inclusive (optional)
--- @field footer_line? integer 0-indexed line number for footer (optional)
--- @field hl_group string Highlight group name
--- @field ordinal? string 2-cell sign stamped in place of the │ border on every continuation row (subagent ordinal); nil leaves the plain border. The identity and ╰─ rows keep their signs regardless. Concealed fence-delimiter rows receive it too but stay zero-height at conceallevel=2, so it does not show there

--- @class agentic.utils.ExtmarkBlock.RenderBlockOpts : agentic.utils.ExtmarkBlock.RenderRailOpts
--- @field header_line integer 0-indexed line number for the identity row
--- @field header_sign string 2-cell identity sign for the opening row
--- @field header_hl_group? string Highlight group for the identity sign; defaults to `hl_group`

--- Renders the continuation rail below a region's identity row: `│` on every
--- body row and `╰─` on the last.
--- @param bufnr integer
--- @param ns_id integer
--- @param opts agentic.utils.ExtmarkBlock.RenderRailOpts
--- @return integer[]
function ExtmarkBlock.render_rail(bufnr, ns_id, opts)
    local decoration_ids = {}

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

--- Renders a complete region: identity sign on the header row, then the rail.
--- Ids come back front-indexed by buffer offset (header first), which
--- `MessageWriter:_stamp_ordinal` relies on to address a single row.
--- @param bufnr integer
--- @param ns_id integer
--- @param opts agentic.utils.ExtmarkBlock.RenderBlockOpts
--- @return integer[]
function ExtmarkBlock.render_block(bufnr, ns_id, opts)
    local decoration_ids = {
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, opts.header_line, 0, {
            sign_text = opts.header_sign,
            sign_hl_group = opts.header_hl_group or opts.hl_group,
        }),
    }

    return vim.list_extend(
        decoration_ids,
        ExtmarkBlock.render_rail(bufnr, ns_id, opts)
    )
end

--- Rewrite one row's border sign in place, reusing the extmark id so no
--- duplicate sign is created.
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
