local assert = require("tests.helpers.assert")
local PlanIndex = require("scripts.plan_index")

local SCRIPT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
    .. "/plan_index.lua"

--- Builds a note titled by its filename.
--- @param name string
--- @param priority integer|nil
--- @param depends string[]|nil
--- @return agentic.PlanIndex.Note note
local function note(name, priority, depends)
    --- @type agentic.PlanIndex.Note
    local n = {
        name = name,
        kind = name:match("^(%u+)%-"),
        title = name,
        priority = priority or 4,
        depends = depends or {},
    }
    return n
end

--- @param components agentic.PlanIndex.Note[][]
--- @return string[][] names
local function names(components)
    return vim.tbl_map(function(component)
        return vim.tbl_map(function(n)
            return n.name
        end, component)
    end, components)
end

describe("scripts/plan_index", function()
    describe("parse", function()
        it("reads every header field", function()
            local parsed = PlanIndex.parse("FIX-a.md", {
                "# Plan: fix a",
                "Status: spec",
                "Priority: P2",
                "Depends: FEAT-b.md, REFACTOR-c.md",
                "",
                "## Background",
                "Priority: P1",
            })
            assert.same({
                name = "FIX-a.md",
                kind = "FIX",
                title = "fix a",
                status = "spec",
                priority = 2,
                depends = { "FEAT-b.md", "REFACTOR-c.md" },
            }, parsed)
        end)

        it("leaves missing fields at their defaults", function()
            local parsed = PlanIndex.parse("IDEA-a.md", {
                "# an idea",
                "Depends:",
            })
            assert.same({
                name = "IDEA-a.md",
                kind = "IDEA",
                title = "an idea",
                priority = 4,
                depends = {},
            }, parsed)
        end)

        it("strips a known label of any case", function()
            for _, h1 in ipairs({ "# PLAN: x", "# Bug: x", "# Audit: x" }) do
                local parsed = PlanIndex.parse("BUG-a.md", { h1 })
                assert.equal("x", parsed and parsed.title)
            end
            local parsed = PlanIndex.parse("BUG-a.md", { "# Bash: x" })
            assert.equal("Bash: x", parsed and parsed.title)
        end)

        it("dedupes Depends", function()
            local parsed =
                PlanIndex.parse("BUG-a.md", { "# x", "Depends: a.md, a.md" })
            assert.same({ "a.md" }, parsed and parsed.depends)
        end)

        it("rejects a note without an H1", function()
            local parsed, err = PlanIndex.parse("BUG-a.md", { "Status: spec" })
            assert.is_nil(parsed)
            assert.equal("no H1 title", err)
        end)

        it("rejects an unknown prefix", function()
            local parsed, err = PlanIndex.parse("bug-a.md", { "# x" })
            assert.is_nil(parsed)
            assert.truthy(err and err:find("prefix"))
        end)

        it("rejects a malformed priority", function()
            local parsed, err =
                PlanIndex.parse("BUG-a.md", { "# x", "Priority: high" })
            assert.is_nil(parsed)
            assert.truthy(err and err:find("high"))
        end)
    end)

    describe("components", function()
        it(
            "orders an either-order pair before their joint dependant",
            function()
                local components = PlanIndex.components({
                    note(
                        "REFACTOR-c.md",
                        3,
                        { "REFACTOR-a.md", "REFACTOR-b.md" }
                    ),
                    note("REFACTOR-b.md", 3),
                    note("REFACTOR-a.md", 3),
                    note("FEAT-z.md"),
                })
                assert.same({
                    { "FEAT-z.md" },
                    { "REFACTOR-a.md", "REFACTOR-b.md", "REFACTOR-c.md" },
                }, components and names(components))
            end
        )

        it("drops a dependency on a missing note", function()
            local components = PlanIndex.components({
                note("FEAT-a.md", 2, { "FEAT-gone.md" }),
            })
            assert.same({ { "FEAT-a.md" } }, components and names(components))
        end)

        it("breaks ties by priority before filename", function()
            local components = PlanIndex.components({
                note("FEAT-a.md", 3),
                note("FEAT-b.md", 1),
                note("FEAT-c.md", nil, { "FEAT-a.md", "FEAT-b.md" }),
            })
            assert.same(
                { { "FEAT-b.md", "FEAT-a.md", "FEAT-c.md" } },
                components and names(components)
            )
        end)

        it("names the notes of a cycle and its dependants", function()
            local components, err = PlanIndex.components({
                note("FEAT-a.md", 2, { "FEAT-b.md" }),
                note("FEAT-b.md", 2, { "FEAT-a.md" }),
                note("FEAT-c.md", 2, { "FEAT-a.md" }),
            })
            assert.is_nil(components)
            assert.equal(
                "cycle in Depends, among these notes and their dependants: "
                    .. "FEAT-a.md, FEAT-b.md, FEAT-c.md",
                err
            )
        end)
    end)

    describe("render", function()
        it("renders a track and each single-note group", function()
            local a = note("REFACTOR-a.md", 3)
            a.status = "spec"
            local b = note("REFACTOR-b.md", 2)
            local c = note("FEAT-c.md", 3, { "REFACTOR-a.md", "REFACTOR-b.md" })
            c.title = "the goal"
            assert.same(
                {
                    "",
                    "### Tracks",
                    "",
                    "**the goal**",
                    "1. P3 [REFACTOR-a.md](notes/REFACTOR-a.md): REFACTOR-a.md — spec",
                    "2. P2 [REFACTOR-b.md](notes/REFACTOR-b.md): REFACTOR-b.md",
                    "3. P3 [FEAT-c.md](notes/FEAT-c.md): the goal (after 1, 2)",
                    "",
                    "### Bugs",
                    "",
                    "- P1 [FIX-f.md](notes/FIX-f.md): FIX-f.md",
                    "- [BUG-e.md](notes/BUG-e.md): BUG-e.md",
                    "",
                    "### Plans",
                    "",
                    "- [TRACK-g.md](notes/TRACK-g.md): TRACK-g.md",
                    "",
                    "### Ideas and audits",
                    "",
                    "- P1 [AUDIT-i.md](notes/AUDIT-i.md): AUDIT-i.md",
                    "- [IDEA-h.md](notes/IDEA-h.md): IDEA-h.md",
                    "",
                },
                PlanIndex.render({
                    { a, b, c },
                    { note("IDEA-h.md") },
                    { note("BUG-e.md") },
                    { note("AUDIT-i.md", 1) },
                    { note("TRACK-g.md") },
                    { note("FIX-f.md", 1) },
                })
            )
        end)

        it("sorts tracks by best priority, then label", function()
            local rendered = PlanIndex.render({
                { note("FEAT-a.md", 3), note("FEAT-b.md", 3, { "FEAT-a.md" }) },
                { note("FEAT-c.md", 2), note("FEAT-d.md", 3, { "FEAT-c.md" }) },
            })
            assert.equal("**FEAT-d.md**", rendered[4])
        end)
    end)

    describe("splice", function()
        it("replaces the region between the markers", function()
            assert.same(
                {
                    "a",
                    "<!-- BEGIN plan-index -->",
                    "new",
                    "<!-- END plan-index -->",
                    "b",
                },
                PlanIndex.splice({
                    "a",
                    "<!-- BEGIN plan-index -->",
                    "old",
                    "<!-- END plan-index -->",
                    "b",
                }, { "new" })
            )
        end)

        it("rejects missing or reversed markers", function()
            for _, todo in ipairs({
                { "<!-- BEGIN plan-index -->" },
                { "<!-- END plan-index -->", "<!-- BEGIN plan-index -->" },
            }) do
                local lines, err = PlanIndex.splice(todo, {})
                assert.is_nil(lines)
                assert.is_not_nil(err)
            end
        end)
    end)

    it("exits 1 in check mode when TODO.md is out of date", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. "/notes", "p")
        vim.fn.writefile(
            { "# Plan: a", "Priority: P2" },
            dir .. "/notes/FEAT-a.md"
        )
        vim.fn.writefile({
            "<!-- BEGIN plan-index -->",
            "<!-- END plan-index -->",
        }, dir .. "/TODO.md")

        local function run(...)
            return vim.system(
                { vim.v.progpath, "--clean", "-l", SCRIPT, ... },
                { cwd = dir, text = true }
            ):wait()
        end

        local stale = run("--check")
        assert.equal(1, stale.code)
        assert.equal(0, run().code)
        assert.equal(0, run("--check").code)
    end)
end)
