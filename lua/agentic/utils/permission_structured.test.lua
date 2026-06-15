--- Tests for the structured option matcher.
---
--- API targeted (see the `permissions` project skill for the overview):
---     extract_option_candidates(token: string) -> string[]
---     match_options(candidates: string[], rule_options: string[]) -> boolean
---     resolve_args(args: string[], cmd_name: string) -> {
---         positionals: string[],
---         option_tokens: string[],
---     }
---     decide_leaf(
---         entries: StructuredEntries,   -- cmd-keyed dict, "*" wildcard key
---         parsed: ParsedLeaf,
---         auto_approve: "allow"|"read-only"|nil
---     ) -> "allow"|"ask"|"deny"|nil

local assert = require("tests.helpers.assert")
local PermissionStructured = require("agentic.utils.permission_structured")

--- Minimal ParsedLeaf stub for matcher tests. The walker (chunk 6) produces
--- the same shape; here the test feeds args directly.
--- @param cmd string
--- @param args string[]
--- @return agentic.ParsedLeaf
local function parsed(cmd, args)
    return {
        cmd_name = cmd,
        args = args,
    }
end

describe("PermissionStructured", function()
    -- ------------------------------------------------------------------
    -- Cluster expansion — extract_option_candidates(token)
    -- ------------------------------------------------------------------
    -- Input is one post-quote-stripped token from the walker. Letter-set
    -- and long-name branches are over-approximate (sound for deny/ask).
    describe("extract_option_candidates", function()
        it("expands a short cluster into letter-set + long-name", function()
            local cands = PermissionStructured.extract_option_candidates("-uo")
            table.sort(cands)
            assert.same({ "o", "u", "uo" }, cands)
        end)

        it("strips =value from a long flag", function()
            local cands =
                PermissionStructured.extract_option_candidates("--output=x")
            assert.same({ "output" }, cands)
        end)

        it("keeps a long flag without =value as the long name", function()
            local cands =
                PermissionStructured.extract_option_candidates("--out=x")
            assert.same({ "out" }, cands)
        end)

        it("emits letter-set + glued-name for short with glued arg", function()
            -- `-oFILE` could be `-o FILE` (POSIX glued arg) or short cluster
            -- `-o -F -I -L -E`. Over-approximate by emitting both, every
            -- letter plus the whole tail as a candidate long-name.
            local cands =
                PermissionStructured.extract_option_candidates("-oFILE")
            table.sort(cands)
            assert.same({ "E", "F", "I", "L", "o", "oFILE" }, cands)
        end)

        it("treats a quote-stripped short flag like its raw form", function()
            local cands = PermissionStructured.extract_option_candidates("-o")
            assert.same({ "o" }, cands)
        end)

        it("returns no candidates for `--` alone", function()
            local cands = PermissionStructured.extract_option_candidates("--")
            assert.same({}, cands)
        end)

        it("returns no candidates for `-` alone", function()
            local cands = PermissionStructured.extract_option_candidates("-")
            assert.same({}, cands)
        end)

        it("returns no candidates for `--=value` (empty long name)", function()
            local cands =
                PermissionStructured.extract_option_candidates("--=value")
            assert.same({}, cands)
        end)

        it("emits a single-char letter set for `-=x`", function()
            local cands = PermissionStructured.extract_option_candidates("-=x")
            table.sort(cands)
            assert.same({ "=", "=x", "x" }, cands)
        end)

        it("returns empty for a positional (no leading dash)", function()
            local cands =
                PermissionStructured.extract_option_candidates("file.txt")
            assert.same({}, cands)
        end)

        it("returns empty for an empty token", function()
            local cands = PermissionStructured.extract_option_candidates("")
            assert.same({}, cands)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Option matching — match_options(candidates, rule_options)
    -- ------------------------------------------------------------------
    describe("match_options", function()
        it("matches a short letter exactly", function()
            assert.is_true(PermissionStructured.match_options({ "o" }, { "o" }))
        end)

        it("does not match a short letter against a different long name", function()
            assert.is_false(
                PermissionStructured.match_options({ "o" }, { "output" })
            )
        end)

        it("matches a long-name candidate that is a prefix of a rule option", function()
            assert.is_true(
                PermissionStructured.match_options({ "out" }, { "output" })
            )
        end)

        it("does not match a long-name candidate when the rule is the prefix", function()
            assert.is_false(
                PermissionStructured.match_options({ "output" }, { "out" })
            )
        end)

        it("matches a long-name candidate exactly", function()
            assert.is_true(
                PermissionStructured.match_options({ "output" }, { "output" })
            )
        end)

        it("matches if any candidate hits the rule list", function()
            assert.is_true(
                PermissionStructured.match_options(
                    { "u", "o", "uo" },
                    { "o" }
                )
            )
        end)

        it("does not match when no candidate hits", function()
            assert.is_false(
                PermissionStructured.match_options({ "x", "y" }, { "o" })
            )
        end)

        it("returns false for empty candidates", function()
            assert.is_false(PermissionStructured.match_options({}, { "o" }))
        end)

        it("returns false for empty rule options", function()
            assert.is_false(PermissionStructured.match_options({ "o" }, {}))
        end)
    end)

    -- ------------------------------------------------------------------
    -- Arg resolution — resolve_args(args, cmd_name)
    -- ------------------------------------------------------------------
    -- Splits args into option_tokens (leading options, including consumed
    -- values for OPTION_VALUE_TAKERS entries) and positionals (the rest).
    -- The first positional is whatever the command treats it as — gates
    -- match positionals[1] uniformly, no subcommand concept in the schema.
    describe("resolve_args", function()
        it("returns the args as positionals when no leading options", function()
            local result =
                PermissionStructured.resolve_args({ "diff" }, "git")
            assert.same({ "diff" }, result.positionals)
            assert.same({}, result.option_tokens)
        end)

        it("skips git's -C <path> arg-taking global", function()
            local result = PermissionStructured.resolve_args(
                { "-C", "path", "diff", "foo" },
                "git"
            )
            assert.same({ "diff", "foo" }, result.positionals)
            assert.same({ "-C", "path" }, result.option_tokens)
        end)

        it("skips git's -c key=val arg-taking global", function()
            local result = PermissionStructured.resolve_args(
                { "-c", "user.name=foo", "log" },
                "git"
            )
            assert.same({ "log" }, result.positionals)
            assert.same({ "-c", "user.name=foo" }, result.option_tokens)
        end)

        it("treats a non-OPTION_VALUE_TAKERS command uniformly", function()
            local result =
                PermissionStructured.resolve_args({ "-la", "/tmp" }, "ls")
            assert.same({ "/tmp" }, result.positionals)
            assert.same({ "-la" }, result.option_tokens)
        end)

        it("returns empty positionals when only options are present (git)", function()
            local result =
                PermissionStructured.resolve_args({ "-C", "path" }, "git")
            assert.same({}, result.positionals)
            assert.same({ "-C", "path" }, result.option_tokens)
        end)

        it("returns empty for an empty arg list", function()
            local result = PermissionStructured.resolve_args({}, "git")
            assert.same({}, result.positionals)
            assert.same({}, result.option_tokens)
        end)

        it("terminates option walk on `--` sentinel", function()
            local result = PermissionStructured.resolve_args(
                { "-la", "--", "-not-a-flag" },
                "ls"
            )
            assert.same({ "-not-a-flag" }, result.positionals)
            assert.same({ "-la" }, result.option_tokens)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Positional matching — exercised via decide_leaf since the public
    -- API matches positionals inside a gate, not as a standalone helper.
    -- ------------------------------------------------------------------
    describe("positional matching (via decide_leaf)", function()
        it("matches a literal first positional", function()
            local entries = {
                git = { read_only = { { positionals = { "push" } } } },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("git", { "push" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("matches a glob in a positional", function()
            local entries = {
                pdftotext = {
                    read_only = { { positionals = { "*.pdf", "-" } } },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("pdftotext", { "foo.pdf", "-" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("allows trailing args beyond the positional pattern", function()
            -- `positionals: ["push"]` matches `git push --foo bar`.
            local entries = {
                git = { read_only = { { positionals = { "push" } } } },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("git", { "push", "--foo", "bar" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("fails when the first positional does not match", function()
            local entries = {
                git = { read_only = { { positionals = { "push" } } } },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("git", { "pop" }),
                "allow"
            )
            assert.is_nil(decision)
        end)

        it("matches the second positional with a glob", function()
            local entries = {
                git = {
                    read_only = {
                        { positionals = { "config", "--get", "*" } },
                    },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("git", { "-C", "path", "config", "--get", "foo" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Gate evaluation within a single cmd entry
    -- ------------------------------------------------------------------
    describe("gate evaluation within an entry", function()
        it("deny fires regardless of a matching allow", function()
            local entries = {
                sed = {
                    read_only = { {} },
                    deny = { { options = { "i" } } },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("sed", { "-i", "s/a/b/", "file" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("ask fires when no deny matches", function()
            local entries = {
                yq = {
                    read_only = { {} },
                    ask = { { options = { "i" } } },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("yq", { "-i", "expr", "file" }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("allow fires when no deny or ask matches", function()
            local entries = { ls = { read_only = { {} } } }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("ls", { "-la" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("empty gate `{}` matches the bare command", function()
            local entries = { grep = { read_only = { {} } } }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("grep", { "pattern", "file" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("an empty kind array `{}` matches nothing", function()
            -- `read_only = {}` carries no gates (distinct from `{{}}`), so
            -- the user's "disable this kind" override yields no allow.
            local entries = { grep = { read_only = {} } }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("grep", { "pattern" }),
                "allow"
            )
            assert.is_nil(decision)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Composition across kind-arrays and the "*" wildcard entry
    -- ------------------------------------------------------------------
    describe("composition across kinds and wildcard", function()
        local find_entry = {
            find = {
                read_only = { {} },
                deny = { { options = { "exec" } } },
            },
        }

        it("allows find with no -exec", function()
            local decision = PermissionStructured.decide_leaf(
                find_entry,
                parsed("find", { ".", "-name", "foo" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("denies find with -exec", function()
            local decision = PermissionStructured.decide_leaf(
                find_entry,
                parsed("find", { ".", "-exec", "rm", "{}" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("deny beats allow within the same cmd entry", function()
            local entries = {
                sort = {
                    read_only = { {} },
                    deny = { { options = { "o", "output" } } },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("sort", { "-o", "out", "in" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("wildcard allow fires when no cmd entry exists", function()
            local entries = {
                ["*"] = { read_only = { { options = { "help" } } } },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("ls", { "--help" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("a cmd deny beats a wildcard allow", function()
            local entries = {
                ["*"] = { read_only = { {} } },
                sort = { deny = { { options = { "o" } } } },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("sort", { "-o", "out" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)
    end)

    -- ------------------------------------------------------------------
    -- vim.NIL-valued entry treated as missing (user disable mechanism)
    -- ------------------------------------------------------------------
    describe("vim.NIL entry handling", function()
        it("treats a vim.NIL cmd entry as missing", function()
            local entries = { ls = vim.NIL }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("ls", { "--help" }),
                "allow"
            )
            assert.is_nil(decision)
        end)

        it("a vim.NIL cmd entry does not shadow the wildcard", function()
            local entries = {
                ls = vim.NIL,
                ["*"] = { read_only = { { options = { "help" } } } },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("ls", { "--help" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Eligible allow kinds (read_only vs safe_write) against auto_approve
    -- ------------------------------------------------------------------
    -- The kind name encodes the policy: read_only auto-approves at
    -- "read-only" or "allow"; safe_write only at "allow". deny/ask are
    -- unconditional. auto_approve=nil admits no allow kind.
    describe("eligible allow kinds", function()
        local mlr_entry = {
            mlr = {
                safe_write = { {} },
                deny = { { options = { "I" } } },
            },
        }

        it("deny wins at auto_approve='allow'", function()
            local decision = PermissionStructured.decide_leaf(
                mlr_entry,
                parsed("mlr", { "-I", "foo" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("deny is unconditional at auto_approve='read-only'", function()
            local decision = PermissionStructured.decide_leaf(
                mlr_entry,
                parsed("mlr", { "-I", "foo" }),
                "read-only"
            )
            assert.equal("deny", decision)
        end)

        it("deny is unconditional at auto_approve=nil", function()
            local decision = PermissionStructured.decide_leaf(
                mlr_entry,
                parsed("mlr", { "-I", "foo" }),
                nil
            )
            assert.equal("deny", decision)
        end)

        it("safe_write allow fires at auto_approve='allow'", function()
            local decision = PermissionStructured.decide_leaf(
                mlr_entry,
                parsed("mlr", { "foo" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("safe_write allow is filtered out at auto_approve='read-only'", function()
            local decision = PermissionStructured.decide_leaf(
                mlr_entry,
                parsed("mlr", { "foo" }),
                "read-only"
            )
            assert.is_nil(decision)
        end)

        it("safe_write allow is filtered out at auto_approve=nil", function()
            local decision = PermissionStructured.decide_leaf(
                mlr_entry,
                parsed("mlr", { "foo" }),
                nil
            )
            assert.is_nil(decision)
        end)

        local cat_entry = { cat = { read_only = { {} } } }

        it("read_only allow fires at auto_approve='read-only'", function()
            local decision = PermissionStructured.decide_leaf(
                cat_entry,
                parsed("cat", { "foo" }),
                "read-only"
            )
            assert.equal("allow", decision)
        end)

        it("read_only allow fires at auto_approve='allow'", function()
            local decision = PermissionStructured.decide_leaf(
                cat_entry,
                parsed("cat", { "foo" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("read_only allow is filtered out at auto_approve=nil", function()
            local decision = PermissionStructured.decide_leaf(
                cat_entry,
                parsed("cat", { "foo" }),
                nil
            )
            assert.is_nil(decision)
        end)
    end)

    -- ------------------------------------------------------------------
    -- End-to-end cases from § Phase 1b tests of the plan
    -- ------------------------------------------------------------------
    describe("plan-enumerated end-to-end cases", function()
        local sort_entry = {
            sort = {
                read_only = { {} },
                deny = { { options = { "o", "output" } } },
            },
        }

        it("denies `sort -uo out` via short cluster", function()
            local decision = PermissionStructured.decide_leaf(
                sort_entry,
                parsed("sort", { "-uo", "out" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("denies `sort --out=x` via GNU abbreviation", function()
            local decision = PermissionStructured.decide_leaf(
                sort_entry,
                parsed("sort", { "--out=x" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("denies `sort -oFILE` via glued arg", function()
            local decision = PermissionStructured.decide_leaf(
                sort_entry,
                parsed("sort", { "-oFILE" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("does not allow `git -C diff push` against positional=diff", function()
            -- `-C diff` is the arg-taking global, `push` is the first
            -- positional. An allow gate keyed on positionals[1]="diff" must
            -- NOT fire.
            local entries = {
                git = { read_only = { { positionals = { "diff" } } } },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("git", { "-C", "diff", "push" }),
                "allow"
            )
            assert.is_nil(decision)
        end)

        it("allows `git -C path config --get foo`", function()
            local entries = {
                git = {
                    read_only = {
                        { positionals = { "config", "--get", "*" } },
                    },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("git", { "-C", "path", "config", "--get", "foo" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("allows `pdftotext *.pdf -` via positional glob", function()
            local entries = {
                pdftotext = {
                    read_only = { { positionals = { "*.pdf", "-" } } },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("pdftotext", { "foo.pdf", "-" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("does not auto-approve bare `tee out` (no entry)", function()
            -- `tee` is intentionally absent from the bundled rules. With no
            -- matching entry, decide_leaf returns nil → caller prompts.
            local decision = PermissionStructured.decide_leaf(
                {},
                parsed("tee", { "out" }),
                "allow"
            )
            assert.is_nil(decision)
        end)

        it("denies `curl -K config.txt`", function()
            local entries = {
                curl = {
                    read_only = { {} },
                    deny = { { options = { "K", "config" } } },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("curl", { "-K", "config.txt" }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("allows `ls --help` via cmd=* options=help", function()
            local entries = {
                ["*"] = {
                    read_only = { { options = { "help", "version" } } },
                },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("ls", { "--help" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        -- Cluster-bypass closure cases (the new ask gates close these holes).
        local pacman_entry = {
            pacman = {
                read_only = { { options = { "Q", "Si", "Ss" } } },
                ask = { { options = { "R", "U", "D", "F", "T" } } },
            },
        }

        it("asks `pacman -QR foo` (R in cluster beats Q read_only)", function()
            local decision = PermissionStructured.decide_leaf(
                pacman_entry,
                parsed("pacman", { "-QR", "foo" }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("allows `pacman -Q kitty` (no destructive letter)", function()
            local decision = PermissionStructured.decide_leaf(
                pacman_entry,
                parsed("pacman", { "-Q", "kitty" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)
    end)
end)
