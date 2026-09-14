local assert = require("tests.helpers.assert")

describe("SkillPath", function()
    --- @type agentic.utils.SkillPath
    local SkillPath
    --- @type string
    local dir

    before_each(function()
        SkillPath = require("agentic.utils.skill_path")
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
    end)

    after_each(function()
        vim.fs.rm(dir, { recursive = true })
    end)

    --- @param path string
    local function touch(path)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        local file = io.open(path, "w")
        assert.is_not_nil(file)
        --- @cast file -nil
        file:close()
    end

    --- @param items string[]
    --- @param wanted string
    --- @return integer|nil
    local function index_of(items, wanted)
        for i, item in ipairs(items) do
            if item == wanted then
                return i
            end
        end
        return nil
    end

    describe("roots", function()
        it("puts ancestors nearest-first, then extras, then $HOME", function()
            local cwd = vim.fs.joinpath(dir, "a", "b")
            vim.fn.mkdir(cwd, "p")
            local extra = vim.fs.joinpath(dir, "extra")
            vim.fn.mkdir(extra, "p")

            local roots = SkillPath.roots(cwd, { extra })

            assert.equal(roots[1], cwd)
            assert.equal(roots[2], vim.fs.joinpath(dir, "a"))
            assert.equal(roots[3], dir)
            local at_extra = index_of(roots, extra)
            assert.is_not_nil(at_extra)
            assert.truthy(at_extra > 3)
            assert.equal(roots[#roots], vim.uv.os_homedir())
        end)

        it("keeps one spelling of a symlinked directory", function()
            local real = vim.fs.joinpath(dir, "real")
            vim.fn.mkdir(real, "p")
            local link = vim.fs.joinpath(dir, "link")
            vim.uv.fs_symlink(real, link)

            local roots = SkillPath.roots(real, { link })

            assert.equal(index_of(roots, real), 1)
            assert.is_nil(index_of(roots, link))
        end)
    end)

    describe("find", function()
        it("returns nil when no root holds the skill", function()
            assert.is_nil(SkillPath.find("coding", { dir }))
        end)

        it("resolves under .agents/skills", function()
            local path = vim.fs.joinpath(dir, ".agents/skills/coding/SKILL.md")
            touch(path)

            assert.equal(SkillPath.find("coding", { dir }), path)
        end)

        it("resolves a directory-scoped <prefix>:<name>", function()
            local path =
                vim.fs.joinpath(dir, "apps/web/.claude/skills/deploy/SKILL.md")
            touch(path)

            assert.equal(SkillPath.find("apps/web:deploy", { dir }), path)
        end)

        it("returns nil for an empty name after the colon", function()
            touch(vim.fs.joinpath(dir, "plugin/.claude/skills/SKILL.md"))

            assert.is_nil(SkillPath.find("plugin:", { dir }))
        end)

        it("takes the skill from the earlier root", function()
            local near = vim.fs.joinpath(dir, "near")
            local far = vim.fs.joinpath(dir, "far")
            local path = vim.fs.joinpath(near, ".claude/skills/coding/SKILL.md")
            touch(path)
            touch(vim.fs.joinpath(far, ".claude/skills/coding/SKILL.md"))

            assert.equal(SkillPath.find("coding", { near, far }), path)
        end)

        it("rejects a directory named SKILL.md", function()
            vim.fn.mkdir(
                vim.fs.joinpath(dir, ".claude/skills/coding/SKILL.md"),
                "p"
            )

            assert.is_nil(SkillPath.find("coding", { dir }))
        end)
    end)
end)
