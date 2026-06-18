local assert = require("tests.helpers.assert")
local ShellParse = require("agentic.utils.shell_parse")

--- Render extracted records as `name -flags args` strings for compact asserts.
--- @param recs agentic.ShellCommand[]|nil
--- @return string[]|nil
local function render(recs)
    if recs == nil then
        return nil
    end
    local out = {}
    for _, r in ipairs(recs) do
        local parts = { r.name }
        vim.list_extend(parts, r.flags)
        vim.list_extend(parts, r.args)
        table.insert(out, table.concat(parts, " "))
    end
    return out
end

--- @return string[] command names in extraction order
local function names(src)
    local recs = ShellParse.extract_commands(src)
    local out = {}
    for _, r in ipairs(recs or {}) do
        table.insert(out, r.name)
    end
    return out
end

describe("ShellParse.extract_commands", function()
    describe("record shape", function()
        it("splits short flag clusters, keeps long flags whole", function()
            assert.same(
                { "rm -r -f x" },
                render(ShellParse.extract_commands("rm -rf x"))
            )
            assert.same(
                { "rm --force x" },
                render(ShellParse.extract_commands("rm --force x"))
            )
        end)

        it("strips a system binary-dir prefix from the name", function()
            assert.same({ "rm" }, names("/usr/bin/rm -f x"))
        end)
    end)

    describe("the headline false positive", function()
        it("does not see rm inside a quoted git commit message", function()
            -- the `rm -f` text is string content, not a command
            assert.same(
                { "git" },
                names('git commit -m "remove the rm -f guard"')
            )
        end)

        it("does not see rm inside a raw-string echo", function()
            assert.same({ "echo", "ls" }, names("echo 'rm -f x' ; ls"))
        end)
    end)

    describe("flattening live substitutions", function()
        it("sees the command inside a $() argument", function()
            assert.same(
                { "git", "printf" },
                names('git commit -m "$(printf rm)"')
            )
        end)

        it("sees rm laundered through a substitution", function()
            assert.same({ "git", "rm" }, names('git commit -m "$(rm -rf /)"'))
        end)
    end)

    describe("transparent prefixes", function()
        it("unwraps an exec-wrapper to the inner command", function()
            assert.same({ "rm -f x" }, render(ShellParse.extract_commands("timeout 5 rm -f x")))
        end)

        it("walks an inline shell -c body", function()
            assert.same({ "rm -f y" }, render(ShellParse.extract_commands("zsh -c 'rm -f y'")))
        end)
    end)

    describe("control flow and pipelines", function()
        it("collects every leaf of a pipeline", function()
            assert.same({ "grep", "head" }, names("grep foo | head -20"))
        end)

        it("recurses into loop bodies", function()
            assert.same({ "rm" }, names("for f in a b; do rm -f $f; done"))
        end)
    end)

    describe("fail-closed (nil, not empty)", function()
        it("returns nil on a parse error", function()
            assert.equal(nil, ShellParse.extract_commands("rm -f $("))
        end)

        it("returns nil on a substitution command name", function()
            assert.equal(nil, ShellParse.extract_commands("$(echo rm) -rf /"))
        end)

        it("returns nil on an expansion command name", function()
            -- `$R` could resolve to anything; a record named `$R` matches no
            -- block rule, so bail rather than emit a name no guard can catch.
            assert.equal(nil, ShellParse.extract_commands("$VAR -rf /"))
            assert.equal(nil, ShellParse.extract_commands("R=rm; $R -f /"))
            assert.equal(nil, ShellParse.extract_commands("${CMD} -f x"))
        end)

        it("returns nil on a code-taking builtin", function()
            assert.equal(nil, ShellParse.extract_commands('eval "rm -f x"'))
        end)

        it("returns empty for a bare string (parsed, no command)", function()
            assert.same({}, ShellParse.extract_commands("# just a comment"))
        end)
    end)
end)
