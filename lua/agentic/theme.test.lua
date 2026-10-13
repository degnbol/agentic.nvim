local assert = require("tests.helpers.assert")

describe("agentic.Theme", function()
    --- @type agentic.Theme
    local Theme

    before_each(function()
        Theme = require("agentic.theme")
    end)

    describe("setup", function()
        --- @param name string
        local function clear(name)
            vim.cmd.highlight({ args = { "clear", name } })
        end

        --- @param name string
        --- @return string|nil
        local function link_of(name)
            return vim.api.nvim_get_hl(0, { name = name }).link
        end

        -- `Prompt` is not one of neovim's own groups, so every case has to say
        -- whether the colorscheme under test defines it. `Normal` is put back
        -- because one case blanks it and the whole file shares one neovim.
        local normal
        before_each(function()
            clear("Prompt")
            normal = vim.api.nvim_get_hl(0, { name = "Normal" })
        end)

        after_each(function()
            vim.api.nvim_set_hl(0, "Normal", normal)
        end)

        -- A `status_hl` entry naming a group `setup` never defines is the
        -- failure mode: `get_status_hl_group` reports it happily and the
        -- footer sign drops through to whatever the row already had.
        it("defines a group for every tool call status", function()
            Theme.setup()

            for _, status in ipairs({
                "pending",
                "in_progress",
                "completed",
                "failed",
                "cancelled",
            }) do
                local group = Theme.get_status_hl_group(status)
                assert.is_not.equal(group, "Comment")
                assert.is_not_nil(link_of(group))
            end
        end)

        it("redefines its groups after a colorscheme wipes them", function()
            Theme.setup()
            vim.cmd.colorscheme("default")

            assert.equal("Normal", link_of(Theme.HL_GROUPS.GLYPH_AGENT))
        end)

        it("points the user glyph at Prompt where it is defined", function()
            vim.api.nvim_set_hl(0, "Prompt", { fg = "#f05af2" })

            Theme.setup()

            assert.equal("Prompt", link_of(Theme.HL_GROUPS.GLYPH_USER))
        end)

        it("falls back to Normal where Prompt is undefined", function()
            Theme.setup()

            assert.equal("Normal", link_of(Theme.HL_GROUPS.GLYPH_USER))
        end)

        it("strikes the off-glyph in the user glyph's foreground", function()
            vim.api.nvim_set_hl(0, "Prompt", { fg = "#abcdef" })

            Theme.setup()

            local off =
                vim.api.nvim_get_hl(0, { name = Theme.HL_GROUPS.GLYPH_OFF })
            assert.equal(tonumber("abcdef", 16), off.fg)
            assert.is_true(off.strikethrough)
        end)

        it(
            "trades the strikethrough for a colour the source cannot give",
            function()
                -- A colorscheme leaving Normal to the terminal resolves to no
                -- foreground, and an attribute-only group would fall through to
                -- SignColumn — dimmer than the glyph this one pairs with.
                vim.api.nvim_set_hl(0, "Normal", {})

                Theme.setup()

                assert.equal(
                    Theme.HL_GROUPS.GLYPH_USER,
                    link_of(Theme.HL_GROUPS.GLYPH_OFF)
                )
            end
        )

        -- The colorscheme need not have cleared for the second setup to take
        -- effect: `default = true` is a no-op on a group that still exists, so
        -- a group resolved before the scheme loaded would otherwise keep that
        -- first answer for the rest of the session.
        it("re-resolves its own groups against a later colorscheme", function()
            Theme.setup()
            assert.equal("Normal", link_of(Theme.HL_GROUPS.GLYPH_USER))

            vim.api.nvim_set_hl(0, "Prompt", { fg = "#f05af2" })
            Theme.setup()

            assert.equal("Prompt", link_of(Theme.HL_GROUPS.GLYPH_USER))
        end)

        -- Twice over: a setup that finds a group it does not own must not
        -- record that group as its own, or the setup after it overwrites what
        -- it just yielded to.
        it("yields to a group defined outside this module", function()
            Theme.setup()
            vim.api.nvim_set_hl(0, Theme.HL_GROUPS.GLYPH_AGENT, {
                link = "Title",
            })

            Theme.setup()
            assert.equal("Title", link_of(Theme.HL_GROUPS.GLYPH_AGENT))

            Theme.setup()
            assert.equal("Title", link_of(Theme.HL_GROUPS.GLYPH_AGENT))
        end)

        -- Driven by the real event rather than a second `setup()` call, the
        -- path where a re-derivation has to survive whatever `:colorscheme`
        -- does to the groups already standing. Runs last — it leaves a
        -- colorscheme and an 'runtimepath' entry behind.
        it("re-resolves over a colorscheme that never clears", function()
            local rtp_dir = vim.fn.tempname()
            vim.fn.mkdir(rtp_dir .. "/colors", "p")
            vim.fn.writefile({
                'vim.g.colors_name = "agentic_noclear"',
                'vim.api.nvim_set_hl(0, "Prompt", { fg = "#f05af2" })',
            }, rtp_dir .. "/colors/agentic_noclear.lua")
            vim.opt.rtp:prepend(rtp_dir)

            Theme.setup()
            assert.equal("Normal", link_of(Theme.HL_GROUPS.GLYPH_USER))

            vim.cmd.colorscheme("agentic_noclear")

            assert.equal("Prompt", link_of(Theme.HL_GROUPS.GLYPH_USER))
        end)
    end)
end)
