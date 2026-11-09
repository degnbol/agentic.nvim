local assert = require("tests.helpers.assert")
local ConfigKeys = require("agentic.utils.config_keys")

describe("ConfigKeys.key_paths toml", function()
    --- @param text string
    --- @return string[][]|nil
    local function paths(text)
        return ConfigKeys.key_paths(text, "toml")
    end

    it("prefixes keys with their [table] header", function()
        assert.same(
            { { "build", "rustc-wrapper" }, { "build", "jobs" } },
            paths('[build]\nrustc-wrapper = "x"\njobs = 2\n')
        )
    end)

    it("reads top-level keys before any table", function()
        assert.same({ { "name" } }, paths('name = "a"\n'))
    end)

    it("splits dotted keys and dotted headers into segments", function()
        assert.same(
            { { "tool", "ruff", "fix" }, { "tool", "ruff", "lint", "select" } },
            paths("[tool.ruff]\nfix = true\nlint.select = []\n")
        )
    end)

    it("reads a quoted key as one segment", function()
        assert.same({ { "a.b" } }, paths('"a.b" = 1\n'))
        assert.same({ { "x", "c.d" } }, paths("[x]\n'c.d' = 1\n"))
    end)

    it("decodes escapes in a basic-string key", function()
        assert.same({ { "build" } }, paths('"\\u0062uild" = 1\n'))
    end)

    it("reads [[array table]] keys without an index", function()
        assert.same(
            { { "bin", "name" }, { "bin", "path" } },
            paths('[[bin]]\nname = "a"\n[[bin]]\nname = "b"\npath = "p"\n')
        )
    end)

    it("flattens inline tables", function()
        assert.same(
            { { "x", "y" }, { "x", "z", "w" } },
            paths("x = { y = 1, z = { w = 2 } }\n")
        )
    end)

    it("flattens inline tables inside arrays", function()
        assert.same(
            { { "hooks", "cmd" }, { "hooks", "args" } },
            paths('hooks = [ { cmd = "a" }, { cmd = "b", args = [] } ]\n')
        )
    end)

    it("ends a path at an array of plain values", function()
        assert.same({ { "select" } }, paths('select = [ "E", "F" ]\n'))
    end)

    it("still yields the path of an empty table", function()
        assert.same(
            { { "inline" }, { "list" }, { "empty" } },
            paths("inline = {}\nlist = []\n[empty]\n")
        )
    end)

    it("ignores comments", function()
        assert.same({ { "a", "b" } }, paths("# c\n[a] # c\nb = 1 # c\n"))
    end)

    it("returns nil on a syntax error", function()
        assert.is_nil(paths("a = = 1\n"))
        assert.is_nil(paths("[a\nb = 1\n"))
    end)
end)

describe("ConfigKeys.key_paths ini", function()
    --- @param text string
    --- @return string[][]|nil
    local function paths(text)
        return ConfigKeys.key_paths(text, "ini")
    end

    it("prefixes keys with their section as written", function()
        assert.same(
            { { "flake8:local-plugins", "extension" }, { "mypy", "plugins" } },
            paths(
                "[flake8:local-plugins]\nextension = X = m:C\n[mypy]\nplugins: p\n"
            )
        )
    end)

    it("lowercases keys", function()
        assert.same({ { "Tool", "addopts" } }, paths("[Tool]\nAddOpts = -x\n"))
    end)

    it("gives every other section the [DEFAULT] keys", function()
        assert.same({
            { "DEFAULT", "plugins" },
            { "mypy", "strict" },
            { "mypy", "plugins" },
        }, paths("[DEFAULT]\nplugins = p\n[mypy]\nstrict = True\n"))
    end)

    it("reads indented lines as the previous key's value", function()
        assert.same(
            { { "options", "install_requires" } },
            paths("[options]\ninstall_requires =\n    a = 1\n    [b]\n")
        )
    end)

    it("ignores comments and blank lines", function()
        assert.same({ { "s", "k" } }, paths("# c\n; c\n\n[s]\n  # c\nk = v\n"))
    end)

    it("still yields the path of an empty section", function()
        assert.same({ { "empty" } }, paths("[empty]\n"))
    end)

    it("returns nil for a key before any section", function()
        assert.is_nil(paths("k = v\n[s]\n"))
    end)

    it("returns nil for a line that is no section, key or comment", function()
        assert.is_nil(paths("[s]\njust words\n"))
        assert.is_nil(paths("[s]\n= v\n"))
    end)

    it("returns nil for an indented line before any key", function()
        assert.is_nil(paths("[s]\n  k = v\n"))
    end)
end)

describe("ConfigKeys.key_paths json", function()
    --- @param text string
    --- @return string[][]|nil
    local function paths(text)
        return ConfigKeys.key_paths(text, "json")
    end

    it("reads nested object keys in sorted order", function()
        assert.same(
            { { "a", "x" }, { "a", "y" }, { "b" } },
            paths('{ "b": 1, "a": { "y": 2, "x": 3 } }')
        )
    end)

    it("reads a key with a dot as one segment", function()
        assert.same(
            { { "runtime.version" } },
            paths('{ "runtime.version": 1 }')
        )
    end)

    it("ends a path at an array of plain values", function()
        assert.same({ { "library" } }, paths('{ "library": [ "a", "b" ] }'))
    end)

    it("flattens objects inside arrays", function()
        assert.same(
            { { "plugins", "name" }, { "plugins", "cmd" } },
            paths('{ "plugins": [ { "name": "a" }, { "cmd": "b" } ] }')
        )
    end)

    it("still yields the path of an empty object, array or null", function()
        assert.same(
            { { "a" }, { "o" }, { "z" } },
            paths('{ "o": {}, "a": [], "z": null }')
        )
    end)

    it("accepts comments", function()
        assert.same({ { "a" } }, paths('{\n  // line\n  "a": /* block */ 1\n}'))
    end)

    it("returns nil for a root that is not an object", function()
        assert.is_nil(paths('"str"'))
        assert.is_nil(paths("[ {} ]"))
        assert.is_nil(paths("[]"))
    end)

    it("returns nil on a syntax error", function()
        assert.is_nil(paths('{ "a": }'))
        assert.is_nil(paths('{ "a": 1, }'))
    end)
end)
