local assert = require("tests.helpers.assert")
local ExecutedCode = require("agentic.utils.executed_code")
local MiniTest = require("mini.test")

--- @param path string
--- @param text string
local function write_file(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path, "b")
end

--- @type string
local base

before_each(function()
    base = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(base, "p")
end)

after_each(function()
    vim.fs.rm(base, { recursive = true })
end)

--- A `read` over the disk.
--- @param path string
--- @return string|nil
local function read_disk(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

describe("ExecutedCode.runs_code", function()
    --- @param items agentic.PermRunsItem[]
    --- @param args string[]|nil
    --- @param cwd string|nil default `base`
    --- @return boolean
    local function runs(items, args, cwd)
        args = args or {}
        local dynamic = vim.tbl_map(function()
            return false
        end, args)
        return ExecutedCode.runs_code(items, args, dynamic, cwd or base)
    end

    it("matches an existing file named by a glob", function()
        local items = { { path = "eslint.config.*" } }
        assert.is_false(runs(items))
        write_file(base .. "/eslint.config.mjs", "export default []")
        assert.is_true(runs(items))
    end)

    it("matches a file holding a listed key", function()
        local items =
            { { path = ".prettierrc", format = "json", keys = { "plugins" } } }
        write_file(base .. "/.prettierrc", '{ "semi": false }')
        assert.is_false(runs(items))
        write_file(base .. "/.prettierrc", '{ "plugins": ["x"] }')
        assert.is_true(runs(items))
    end)

    it("matches a file holding a key outside except_keys", function()
        local items = {
            {
                path = ".cargo/config.toml",
                format = "toml",
                except_keys = { "build.jobs", "term.*" },
            },
        }
        write_file(
            base .. "/.cargo/config.toml",
            "[build]\njobs = 2\n[term]\nquiet = true\n"
        )
        assert.is_false(runs(items))
        write_file(
            base .. "/.cargo/config.toml",
            "[build]\nrustc-wrapper = 'x'\n"
        )
        assert.is_true(runs(items))
    end)

    it("matches a file that does not parse", function()
        local items =
            { { path = ".prettierrc", format = "json", keys = { "plugins" } } }
        write_file(base .. "/.prettierrc", "semi: false\n")
        assert.is_true(runs(items))
    end)

    it("searches every parent with up", function()
        local sub = base .. "/repo/a/b"
        vim.fn.mkdir(base .. "/repo/.git", "p")
        vim.fn.mkdir(sub, "p")
        local items = { { path = ".lintr", up = true } }
        assert.is_false(runs(items, nil, sub))
        write_file(base .. "/.lintr", "")
        assert.is_true(runs(items, nil, sub))
        assert.is_false(runs({ { path = ".lintr" } }, nil, sub))
    end)

    it("matches a file name in any case", function()
        write_file(base .. "/ESLINT.CONFIG.JS", "")
        assert.is_true(runs({ { path = "eslint.config.*" } }))
    end)

    it("reads a key holding dots as the nested keys it spells", function()
        local items = {
            {
                path = ".luarc.json",
                format = "json",
                keys = { "runtime.plugin" },
            },
        }
        write_file(base .. "/.luarc.json", '{ "runtime.plugin": "p.lua" }')
        assert.is_true(runs(items))
        write_file(base .. "/.luarc.json", '{ "runtime.pluginx": "p.lua" }')
        assert.is_false(runs(items))
    end)

    it("anchors at the one directory operand", function()
        local items = {
            {
                path = ".luarc.json",
                format = "json",
                anchor = "operand",
                keys = { "runtime.plugin" },
            },
        }
        vim.fn.mkdir(base .. "/proj", "p")
        write_file(
            base .. "/proj/.luarc.json",
            '{ "runtime": { "plugin": "p.lua" } }'
        )
        assert.is_true(runs(items, { "--check", "proj" }))
        assert.is_true(runs(items, { "--check=proj" }))
        write_file(
            base .. "/proj/.luarc.json",
            '{ "runtime": { "version": "LuaJIT" } }'
        )
        assert.is_false(runs(items, { "--check", "proj" }))
        assert.is_true(runs(items, { "--logpath", base, "--check", "proj" }))
        assert.is_true(
            ExecutedCode.runs_code(
                items,
                { "--check", "$d" },
                { false, true },
                base
            )
        )
    end)
end)

describe("ExecutedCode.READERS", function()
    it("reads a shell script as one command in the cwd", function()
        write_file(base .. "/run.sh", "ls\n")
        local code = ExecutedCode.READERS.zsh(
            { "run.sh" },
            { false },
            base,
            read_disk,
            {}
        )
        assert.same({ dir = base, commands = { "ls\n" } }, code)
        assert.is_nil(
            ExecutedCode.READERS.zsh({ "run.sh" }, { false }, base, function()
                return nil
            end, {})
        )
    end)

    it("reads the make recipes a target runs", function()
        write_file(base .. "/Makefile", "lint:\n\techo hi\n")
        local make = ExecutedCode.READERS.make
        assert.same(
            { dir = base, commands = { "echo hi" } },
            make({ "lint" }, { false }, base, read_disk, {})
        )
        assert.is_nil(
            make({ "-n", "lint" }, { false, false }, base, read_disk, {})
        )
        assert.is_nil(
            make({ "X=1", "lint" }, { false, false }, base, read_disk, {})
        )
        assert.is_nil(make({ "lint" }, { true }, base, read_disk, {}))
        assert.is_nil(make({ "lint" }, { false }, nil, read_disk, {}))
    end)

    it("reads the just recipes a name runs", function()
        if vim.fn.executable("just") == 0 then
            MiniTest.skip("just is not installed")
        end
        write_file(base .. "/justfile", "lint:\n    echo hi\n")
        local just = ExecutedCode.READERS.just
        assert.same(
            { dir = base, commands = { "echo hi" } },
            just({ "lint" }, { false }, base, read_disk, {})
        )
        write_file(
            base .. "/justfile",
            "v := x'$HOME'\nlint:\n    echo {{v}}\n"
        )
        assert.is_nil(just({ "lint" }, { false }, base, read_disk, {}))
        write_file(base .. "/other.just", "b:\n    echo b\n")
        write_file(
            base .. "/justfile",
            "import 'other.just'\nlint:\n    echo hi\n"
        )
        assert.is_nil(just({ "lint" }, { false }, base, read_disk, {}))
    end)
end)
