local assert = require("tests.helpers.assert")
local MakeRecipe = require("agentic.utils.make_recipe")

--- @type agentic.MakePatternRule[]
local BUILTINS = {
    { target = "%.o", prerequisites = { "%.c" }, terminal = false },
    { target = "%", prerequisites = { "%.c" }, terminal = false },
    { target = "%", prerequisites = { "%.o" }, terminal = false },
    { target = "%", prerequisites = { "s.%" }, terminal = true },
}

--- @param files string[]
--- @return fun(path: string): boolean
local function files_exist(files)
    local set = {}
    for _, f in ipairs(files) do
        set[f] = true
    end
    return function(path)
        return set[path] == true
    end
end

--- Recipe commands of `lines` for `targets`, no files existing.
--- @param lines string[] makefile lines
--- @param targets string[]|nil
--- @param files string[]|nil existing files
--- @return string[]|nil
local function run(lines, targets, files)
    return MakeRecipe.commands(
        table.concat(lines, "\n") .. "\n",
        targets or {},
        BUILTINS,
        files_exist(files or {}),
        "Makefile"
    )
end

describe("MakeRecipe.commands", function()
    it("runs the first target's recipe by default", function()
        assert.same(
            { "echo hi" },
            run({ "all:", "\techo hi", "other:", "\techo no" })
        )
    end)

    it("skips .PHONY when choosing the default goal", function()
        assert.same(
            { "echo all" },
            run({ ".PHONY: all", "all:", "\techo all" })
        )
    end)

    it("uses .DEFAULT_GOAL when assigned", function()
        assert.same(
            { "echo b" },
            run({ ".DEFAULT_GOAL := b", "a:", "\techo a", "b:", "\techo b" })
        )
    end)

    it("runs operand targets in order", function()
        assert.same(
            { "echo b", "echo a" },
            run({ "a:", "\techo a", "b:", "\techo b" }, { "b", "a" })
        )
    end)

    it("runs prerequisites first, each target once", function()
        assert.same(
            { "echo b", "echo a", "echo all" },
            run({
                "all: b a",
                "\techo all",
                "a: b",
                "\techo a",
                "b:",
                "\techo b",
            })
        )
    end)

    it("keeps one command per recipe line and strips @ and -", function()
        assert.same(
            { "echo one", "rm x", "echo three # shell comment" },
            run({
                "# make comment",
                "all:",
                "\t@echo one",
                "",
                "# between recipe lines",
                "\t-@rm x",
                "\techo three # shell comment",
            })
        )
    end)

    it("keeps a recipe continuation as one command", function()
        assert.same(
            { "for f in a; do \\\n  echo $f; \\\ndone" },
            run({
                "all:",
                "\tfor f in a; do \\",
                "\t  echo $$f; \\",
                "\tdone",
            })
        )
    end)

    it("joins assignment continuations with one space", function()
        assert.same(
            { "echo a b c" },
            run({ "V = a   \\", "    b\\", "c", "all:", "\techo $(V)" })
        )
    end)

    it("expands every reference form and $$", function()
        assert.same(
            { "echo x x x $HOME" },
            run({ "V = x", "all:", "\techo $(V) ${V} $V $$HOME" })
        )
    end)

    it("expands = late and := at assignment", function()
        assert.same(
            { "echo 2 1" },
            run({
                "b = 1",
                "r = $(b)",
                "s := $(b)",
                "b = 2",
                "all:",
                "\techo $(r) $(s)",
            })
        )
    end)

    it("appends with += by the variable's flavour", function()
        assert.same(
            { "echo 2 2 | 2 1" },
            run({
                "b = 1",
                "r = $(b)",
                "r += 2",
                "s := 2",
                "s += $(b)",
                "b = 2",
                "all:",
                "\techo $(r) | $(s)",
            })
        )
    end)

    it("reads \\# as a literal # and keeps a value's trailing space", function()
        assert.same(
            { "echo [a#b ]" },
            run({ "V = a\\#b # comment", "all:", "\techo [$(V)]" })
        )
    end)

    it("expands automatic variables over merged prerequisites", function()
        assert.same(
            { "cc -o all b c a d" },
            run({
                "all: a",
                "all: b c",
                "\tcc -o $@ $^",
                "all: a d",
                ".PHONY: a b c d",
            })
        )
        assert.same(
            { "cp b all" },
            run({ "all: b a b", "\tcp $< $@", ".PHONY: a b" })
        )
    end)

    it("expands automatic variables inside a recursive variable", function()
        assert.same(
            { "cc -o all" },
            run({ "cmd = cc -o $@", "all:", "\t$(cmd)" })
        )
    end)

    it("strips prefixes that come from expansion", function()
        assert.same({ "echo hi" }, run({ "q = @", "all:", "\t$(q)echo hi" }))
    end)

    it("drops a recipe line that expands to nothing", function()
        assert.same({ "echo b" }, run({ "e =", "all:", "\t$(e)", "\techo b" }))
    end)

    it(
        "applies target-specific variables to the target and its prerequisites",
        function()
            assert.same(
                { "echo dep 2 t", "echo all 2 t s" },
                run({
                    "g = 1",
                    "all: g += t",
                    "all: v := s",
                    "all: dep",
                    "\techo all $(g) $(v)",
                    "dep:",
                    "\techo dep $(g)",
                    "g = 2",
                })
            )
        end
    )

    it("expands a target-specific += late, over a simple base", function()
        assert.same(
            { "echo s 2" },
            run({
                "s := s",
                "all: s += $(x)",
                "x = 1",
                "all:",
                "\techo $(s)",
                "x = 2",
            })
        )
    end)

    it("accepts an existing prerequisite that no rule builds", function()
        assert.same(
            { "cat in.txt" },
            run({ "all: in.txt", "\tcat $<" }, nil, { "in.txt" })
        )
    end)

    it(
        "accepts a recipe-less rule target no built-in rule can build",
        function()
            assert.same({ "echo b" }, run({ "all: b", "b:", "\techo b" }))
        end
    )

    describe("declines", function()
        local cases = {
            ["?="] = { "v ?= x", "all:", "\techo $(v)" },
            ["+= without an earlier assignment"] = {
                "v += x",
                "all:",
                "\techo $(v)",
            },
            ["::="] = { "v ::= x", "all:", "\techo $(v)" },
            ["!="] = { "v != date", "all:", "\techo $(v)" },
            ["$(shell)"] = { "all:", "\techo $(shell date)" },
            ["$(wildcard)"] = { "v = $(wildcard *.c)", "all:", "\techo $(v)" },
            ["a substitution reference"] = {
                "v = a",
                "all:",
                "\techo $(v:a=b)",
            },
            ["a computed name"] = {
                "v = a",
                "a = b",
                "all:",
                "\techo $($(v))",
            },
            ["include"] = { "include other.mk", "all:", "\techo" },
            ["-include"] = { "-include other.mk", "all:", "\techo" },
            ["sinclude"] = { "sinclude other.mk", "all:", "\techo" },
            ["load"] = { "load ext.so", "all:", "\techo" },
            ["ifeq"] = { "ifeq (a,a)", "all:", "\techo", "endif" },
            ["ifdef"] = { "ifdef v", "all:", "\techo", "else", "endif" },
            ["define"] = { "define v", "x", "endef", "all:", "\techo" },
            ["export"] = { "export v = x", "all:", "\techo" },
            ["bare export"] = { "export", "all:", "\techo" },
            ["unexport"] = { "unexport v", "all:", "\techo" },
            ["override"] = { "override v = x", "all:", "\techo" },
            ["vpath"] = { "vpath %.c src", "all:", "\techo" },
            ["$(MAKE)"] = { "all:", "\t$(MAKE) -C sub" },
            ["${MAKE}"] = { "all:", "\t${MAKE} -C sub" },
            ["a + prefix"] = { "all:", "\t+echo hi" },
            ["a + prefix after @"] = { "all:", "\t@+echo hi" },
            ["a + prefix from expansion"] = {
                "p = +",
                "all:",
                "\t$(p)echo hi",
            },
            ["a pattern rule"] = { "%.o: %.c", "\tcc $<" },
            ["a special target"] = { ".ONESHELL:", "all:", "\techo" },
            ["a double-colon rule"] = { "all::", "\techo" },
            ["a static pattern rule"] = { "a.o: %.o: %.c", "\tcc" },
            ["an inline recipe"] = { "all: ; echo hi" },
            ["an order-only prerequisite"] = { "all: | b", "\techo", "b:" },
            ["a wildcard prerequisite"] = { "all: *.c", "\techo" },
            ["a -l prerequisite"] = { "all: -lm", "\techo" },
            ["an archive member"] = { "lib.a(m.o): m.o", "\tar r $@ $<" },
            ["an unassigned variable"] = { "all:", "\techo $(HOME)" },
            ["an unassigned variable in :="] = { "v := $(u)", "all:", "\techo" },
            ["a variable assigned only later, in :="] = {
                "v := $(u)",
                "u = 1",
                "all:",
                "\techo $(v)",
            },
            ["an automatic variable outside a recipe"] = {
                "v := $@",
                "all:",
                "\techo",
            },
            ["an unterminated reference"] = { "all:", "\techo $(v" },
            ["a trailing $"] = { "all:", "\techo $" },
            ["a recursive cycle"] = {
                "a = $(b)",
                "b = $(a)",
                "all:",
                "\techo $(a)",
            },
            ["SHELL"] = { "SHELL = /bin/bash", "all:", "\techo" },
            [".SHELLFLAGS"] = { ".SHELLFLAGS = -ec", "all:", "\techo" },
            ["MAKEFLAGS"] = { "MAKEFLAGS += -j", "all:", "\techo" },
            [".RECIPEPREFIX"] = { ".RECIPEPREFIX = >", "all:", "\techo" },
            ["PATH"] = { "PATH = /tmp", "all:", "\techo" },
            ["CC"] = { "CC = gcc", "all:", "\t$(CC)" },
            ["a target-specific SHELL"] = {
                "all: SHELL = /bin/bash",
                "all:",
                "\techo",
            },
            ["a rule for the makefile"] = {
                "all:",
                "\techo",
                "Makefile: gen",
                "\tgen",
            },
            ["two recipes for one target"] = {
                "all:",
                "\techo 1",
                "all:",
                "\techo 2",
            },
            ["a missing prerequisite without a rule"] = {
                "all: missing",
                "\techo",
            },
            ["a dependency cycle"] = {
                "all: a",
                "\techo all",
                "a: all",
                "\techo a",
            },
            ["a multi-word .DEFAULT_GOAL"] = {
                ".DEFAULT_GOAL = a b",
                "a:",
                "\techo a",
                "b:",
                "\techo b",
            },
            ["a recipe line before any rule"] = { "\techo", "all:", "\techo" },
            ["a recipe line after an assignment"] = {
                "all:",
                "\techo",
                "v = 1",
                "\techo after",
            },
            ["a target-specific += with no global value"] = {
                "all: dep",
                "\techo",
                "dep: v += x",
                "dep:",
                "\techo $(v)",
            },
            ["an unrecognised line"] = { "all:", "\techo", "garbage" },
            ["no target"] = { "v = 1" },
            ["a trailing continuation"] = { "v = a \\" },
        }
        for name, lines in pairs(cases) do
            it(name, function()
                assert.is_nil(run(lines))
            end)
        end

        it(
            "a target-specific += reached without the parent that sets it",
            function()
                assert.is_nil(run({
                    "all: dep",
                    "all: v = 1",
                    "dep: v += x",
                    "all:",
                    "\techo",
                    "dep:",
                    "\techo $(v)",
                }, { "dep" }))
            end
        )

        it("an operand that assigns a variable", function()
            assert.is_nil(run({ "all:", "\techo" }, { "v=1" }))
        end)

        it("a recipe-less target a built-in rule builds from a file", function()
            assert.is_nil(run({ "all: foo.o" }, nil, { "foo.c" }))
        end)

        it("a target a built-in chain builds", function()
            -- prog <- %: %.o <- prog.o (intermediate) <- %.o: %.c <- prog.c
            assert.is_nil(
                MakeRecipe.commands(
                    "all: prog\n",
                    {},
                    { BUILTINS[1], BUILTINS[3] },
                    files_exist({ "prog.c", "prog" }),
                    "Makefile"
                )
            )
        end)

        it("a target a built-in rule builds from a mentioned file", function()
            assert.is_nil(run({ "all: foo", "foo.c:", ".PHONY: all" }))
        end)

        it("a target a terminal built-in rule builds", function()
            assert.is_nil(run({ "all: v" }, nil, { "s.v", "v" }))
        end)

        it("a makefile a built-in rule can remake", function()
            assert.is_nil(run({ "all:", "\techo" }, nil, { "Makefile.c" }))
        end)

        -- make expands an exported variable (one inherited from the
        -- environment) for every recipe it runs, used or not.
        local unused_cases = {
            ["an unused function call"] = {
                "TERM = $(shell touch pwned)",
                "lint:",
                "\tls",
            },
            ["an unused unassigned reference"] = { "v = $(u)", "all:", "\tls" },
            ["an unused cycle"] = {
                "a = $(b)",
                "b = $(a)",
                "all:",
                "\tls",
            },
            ["an unused target-specific function call"] = {
                "all: v = $(shell touch pwned)",
                "all:",
                "\tls",
            },
            ["an unused inherited target-specific function call"] = {
                "all: dep",
                "all: v = $(shell touch pwned)",
                "dep:",
                "\tls",
            },
        }
        for name, lines in pairs(unused_cases) do
            it(name, function()
                assert.is_nil(run(lines))
            end)
        end
    end)

    it("expands an unused variable with automatic variables", function()
        assert.same({ "ls" }, run({ "cmd = cc -o $@", "all:", "\tls" }))
    end)

    it("strips leading ./ from goals, targets and prerequisites", function()
        local lines = {
            ".PHONY: build",
            "build: ./dep",
            "\techo build $^",
            ".//./dep:",
            "\techo dep",
        }
        assert.same(
            { "echo dep", "echo build dep" },
            run(lines, { ".//./build" }, { "build" })
        )
    end)

    it("reads ./Makefile as the makefile", function()
        assert.is_nil(run({ "all:", "\techo", "./Makefile:", "\tgen" }))
    end)

    it("does not chain a match-anything rule into an intermediate", function()
        -- w <- %: %.o <- w.o; %: %.c may not build the intermediate w.o
        assert.same(
            { "echo all" },
            run({ "all: w", "\techo all" }, nil, { "w.o.c", "w" })
        )
    end)

    it("matches built-in patterns against the file name part", function()
        assert.is_nil(run({ "all: sub/q.o" }, nil, { "sub/q.c" }))
    end)
end)

describe("MakeRecipe.builtin_patterns", function()
    local dump = table.concat({
        "# Variables",
        "",
        "# default",
        "COMPILE.c = $(CC) $(CFLAGS) -c",
        "# makefile",
        "MAKEFILE_LIST := ",
        "# environment",
        "PATH = /usr/bin:/bin",
        "",
        "# Implicit Rules",
        "",
        "%.o:",
        "",
        "%.o: %.c",
        "#  commands to execute (built-in):",
        "\t$(COMPILE.c) $(OUTPUT_OPTION) $<",
        "",
        "%.c: %.w %.ch",
        "#  commands to execute (built-in):",
        "\t$(CTANGLE) $^ $@",
        "",
        "%:: s.%",
        "#  commands to execute (built-in):",
        "\t$(GET) $<",
        "",
        "# 4 implicit rules, 1 (25.0%) terminal.",
        "",
        "# Files",
        "",
        "# Not a target:",
        ".SUFFIXES: .o .c .y .tab.c",
        "",
        "# Not a target:",
        "/dev/null:",
        "#  Implicit rule search has not been done.",
        "",
        "# Not a target:",
        ".c.o:",
        "#  commands to execute (built-in):",
        "\t$(COMPILE.c) $(OUTPUT_OPTION) $<",
        "",
        "# Not a target:",
        ".y.tab.c:",
        "#  commands to execute (built-in):",
        "\t$(YACC.y) $<",
        "",
        "# Not a target:",
        ".y:",
        "#  commands to execute (built-in):",
        "\t$(YACC.y) $<",
        "",
        "# Not a target:",
        ".o.c:",
        "",
    }, "\n")

    it("reads pattern rules with a recipe and suffix rules", function()
        assert.same({
            { target = "%.o", prerequisites = { "%.c" }, terminal = false },
            {
                target = "%.c",
                prerequisites = { "%.w", "%.ch" },
                terminal = false,
            },
            { target = "%", prerequisites = { "s.%" }, terminal = true },
            {
                target = "%.tab.c",
                prerequisites = { "%.y" },
                terminal = false,
            },
            { target = "%", prerequisites = { "%.y" }, terminal = false },
        }, MakeRecipe.builtin_patterns(dump))
    end)
end)
