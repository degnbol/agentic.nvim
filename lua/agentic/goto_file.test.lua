local MiniTest = require("mini.test")
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.GotoFile", function()
    local GotoFile = require("agentic.goto_file")
    local SessionRegistry = require("agentic.session_registry")

    --- @type string
    local dir
    --- @type string
    local skill_md
    --- @type TestStub
    local owner_stub

    --- Session stub whose agent gives `dir` as its only root.
    --- @param session_id string|nil
    --- @return table session
    local function owner(session_id)
        return {
            session_id = session_id,
            agent = {
                session_roots = function()
                    return { dir }
                end,
            },
        }
    end

    before_each(function()
        dir = vim.fn.tempname()
        local skill_dir = vim.fs.joinpath(dir, ".claude/skills/x")
        vim.fn.mkdir(skill_dir, "p")
        skill_md = vim.fs.joinpath(skill_dir, "SKILL.md")
        vim.fn.writefile({ "# x" }, skill_md)

        owner_stub = spy.stub(SessionRegistry, "owner_of_buf")
        owner_stub:returns(owner("s-1"))
    end)

    after_each(function()
        owner_stub:revert()
        vim.fs.rm(dir, { recursive = true })
    end)

    describe("resolve", function()
        it("gives a skill's SKILL.md for /name", function()
            assert.equal(skill_md, GotoFile.resolve("/x"))
        end)

        for _, fname in ipairs({ "/missing", "x", "/a/b", "/plugin:x" }) do
            it("returns " .. fname .. " unchanged", function()
                assert.equal(fname, GotoFile.resolve(fname))
            end)
        end

        it("returns the name unchanged without an owner", function()
            owner_stub:returns(nil)

            assert.equal("/x", GotoFile.resolve("/x"))
        end)

        it("returns the name unchanged before the ACP session exists", function()
            owner_stub:returns(owner(nil))

            assert.equal("/x", GotoFile.resolve("/x"))
        end)
    end)

    it("makes gf open a skill from an AgenticInput buffer", function()
        owner_stub:revert()
        local session_id = 1000
        SessionRegistry.by_id[session_id] = owner("s-1")
        local bufnr = vim.api.nvim_create_buf(false, true)
        MiniTest.finally(function()
            SessionRegistry.by_id[session_id] = nil
            for _, buf in ipairs({ bufnr, vim.fn.bufnr(skill_md) }) do
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
            end
        end)
        vim.b[bufnr].agentic_session_id = session_id
        vim.api.nvim_set_current_buf(bufnr)
        vim.bo[bufnr].filetype = "AgenticInput"
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "run /x now" })
        vim.api.nvim_win_set_cursor(0, { 1, 5 })

        vim.cmd.normal({ "gf", bang = true })

        assert.equal(
            vim.fn.resolve(skill_md),
            vim.fn.resolve(vim.api.nvim_buf_get_name(0))
        )
    end)
end)
