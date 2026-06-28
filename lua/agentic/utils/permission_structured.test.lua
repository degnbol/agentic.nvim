--- Tests for the structured option matcher.
---
--- API targeted (see the `permissions` project skill for the overview):
---     extract_option_candidates(token: string) -> string[]
---     match_options(candidates: string[], rule_options: string[]) -> boolean
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

        it("matches a subcommand positional plus a post-subcommand option", function()
            -- Migrated from the old positional-embedded-flag shape
            -- (`["config", "--get", "*"]`): dash-tokens are always stripped to
            -- the order-free `options` set now.
            local entries = {
                git = {
                    read_only = {
                        { positionals = { "config" }, options = { "get" } },
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
    -- End-to-end cases (see the `permissions` skill § "Compound Bash commands")
    -- ------------------------------------------------------------------
    describe("end-to-end cases", function()
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
                        { positionals = { "config" }, options = { "get" } },
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

    -- ------------------------------------------------------------------
    -- Dynamic-token wildcard (use-site gate fix)
    -- ------------------------------------------------------------------
    -- A dynamic arg (`args_dynamic[i] == true`) is treated as a wildcard for
    -- deny/ask gates only: it satisfies any `options` requirement and any
    -- positional pattern at or after its index. Allow gates stay concrete so a
    -- dynamic token never widens an approval.
    describe("dynamic-token wildcard", function()
        --- @param cmd string
        --- @param args string[]
        --- @param dyn boolean[]
        --- @return agentic.ParsedLeaf
        local function parsed_dyn(cmd, args, dyn)
            return { cmd_name = cmd, args = args, args_dynamic = dyn }
        end

        local find_entry = {
            find = { read_only = { {} }, deny = { { options = { "exec" } } } },
        }

        it("a dynamic positional satisfies an options deny gate", function()
            local decision = PermissionStructured.decide_leaf(
                find_entry,
                parsed_dyn("find", { ".", "$f" }, { false, true }),
                "allow"
            )
            assert.equal("deny", decision)
        end)

        it("a fully-static find . -name x is unaffected", function()
            local decision = PermissionStructured.decide_leaf(
                find_entry,
                parsed_dyn("find", { ".", "-name", "x" }, { false, false, false }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        local git_entry = {
            git = {
                read_only = { { positionals = { "log" } } },
                ask = { { positionals = { "branch" } } },
            },
        }

        it("a dynamic positional[0] reaches a positional-keyed ask gate", function()
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed_dyn("git", { "$sub" }, { true }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("a dynamic token after a pinned positional stays approved", function()
            -- positional[0] = "log" (static) keeps the allow gate; the dynamic
            -- "$ref" at index 1 cannot reach the index-0 "branch" ask gate.
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed_dyn("git", { "log", "$ref" }, { false, true }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("a dynamic token does not widen an allow gate (no gate ⇒ nil)", function()
            -- `ls` has no entry here, so a dynamic token approves nothing — it
            -- must not be coerced into matching an absent allow gate.
            local decision = PermissionStructured.decide_leaf(
                { ls = { read_only = { { positionals = { "src" } } } } },
                parsed_dyn("ls", { "$dir" }, { true }),
                "allow"
            )
            assert.is_nil(decision)
        end)

        -- A dynamic token consumed as an option value (-C is in
        -- OPTION_VALUE_TAKERS for git) leaves the positional stream, but can
        -- word-split at runtime to inject a positional ahead of the visible
        -- one — so it must wildcard positional-keyed gates from index 1.
        it("a dynamic consumed option value reaches a positional ask gate", function()
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed_dyn("git", { "-C", "$x", "log" }, { false, true, false }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("a static consumed option value leaves the gate concrete", function()
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed_dyn("git", { "-C", "/repo", "log" }, { false, false, false }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        -- `leading_options` matches only the leading option region and is
        -- wildcard-reachable only by a token that can occupy it. So a leading
        -- `-c` (concrete or via a dynamic first positional) trips it, while a
        -- trailing dynamic positional and a post-subcommand `-c` do not.
        local leading_entry = {
            git = {
                read_only = { { positionals = { "log" } } },
                ask = { { leading_options = { "c", "config" } } },
            },
        }

        it("a concrete leading -c trips a leading_options gate", function()
            local decision = PermissionStructured.decide_leaf(
                leading_entry,
                parsed_dyn("git", { "-c", "x", "log" }, { false, false, false }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("a trailing dynamic positional cannot reach a leading_options gate", function()
            local decision = PermissionStructured.decide_leaf(
                leading_entry,
                parsed_dyn("git", { "log", "$ref" }, { false, true }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("a dynamic first positional can inject a leading flag", function()
            local decision = PermissionStructured.decide_leaf(
                leading_entry,
                parsed_dyn("git", { "$sub" }, { true }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("a post-subcommand -c does not match a leading_options gate", function()
            local decision = PermissionStructured.decide_leaf(
                leading_entry,
                parsed_dyn("git", { "log", "-c" }, { false, false }),
                "allow"
            )
            assert.equal("allow", decision)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Absorption matching (correction step): no getopt arity table for
    -- deny/ask. Each leading flag absorbs 0 or 1 following plain word; deny/ask
    -- match existentially over the parses, allow over the single value_options
    -- parse. git's gates are 100% positional[1] (subcommand) keyed, so a flag
    -- that shifts the subcommand in the took-0 parse exposes it.
    -- ------------------------------------------------------------------
    describe("absorption matching", function()
        -- Mirrors the bundled git entry shape (subcommand-keyed throughout).
        local git_entry = {
            git = {
                read_only = {
                    { positionals = { "log" } },
                    { positionals = { "diff" } },
                },
                ask = {
                    { positionals = { "push" } },
                    { positionals = { "commit" } },
                    { leading_options = { "c", "config-env" } },
                },
            },
        }

        it("allows `git -C /repo log` (value-taker absorbs /repo)", function()
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed("git", { "-C", "/repo", "log" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("asks `git -C push log` (took-0 parse reads push as subcommand)", function()
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed("git", { "-C", "push", "log" }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("asks `git -p push` (zero-arity global can't hide push)", function()
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed("git", { "-p", "push" }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("asks `git --no-pager push`", function()
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed("git", { "--no-pager", "push" }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("asks `git --new-global val push` (unknown value-taker, no table)", function()
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed("git", { "--new-global", "val", "push" }),
                "allow"
            )
            assert.equal("ask", decision)
        end)

        it("prompts `git --foo ci log` (single-parse allow: unknown subcommand ci)", function()
            -- A leading bare flag could launder a true subcommand to a
            -- read-only alternate parse under existential allow; single-parse
            -- allow defaults --foo to absorb-0, so the subcommand is `ci`
            -- (∉ read_only) and falls through to a prompt.
            local decision = PermissionStructured.decide_leaf(
                git_entry,
                parsed("git", { "--foo", "ci", "log" }),
                "allow"
            )
            assert.is_nil(decision)
        end)

        it("allows `xargs -0 ls` (unlisted leading flag absorbs 0)", function()
            local decision = PermissionStructured.decide_leaf(
                { xargs = { read_only = { { positionals = { "ls" } } } } },
                parsed("xargs", { "-0", "ls" }),
                "allow"
            )
            assert.equal("allow", decision)
        end)

        it("asks `gh -R x issue create` (multi-element existential)", function()
            -- The one bundled multi-element existential gate; -R absorbs `x` in
            -- the parse whose stream is `issue create`.
            local entries = {
                gh = { ask = { { positionals = { "issue", "create" } } } },
            }
            local decision = PermissionStructured.decide_leaf(
                entries,
                parsed("gh", { "-R", "x", "issue", "create" }),
                "allow"
            )
            assert.equal("ask", decision)
        end)
    end)

    -- ------------------------------------------------------------------
    -- classify_leaf — category-level, mode-independent classification
    -- ------------------------------------------------------------------
    describe("classify_leaf", function()
        it("reports read_only for a matching read_only gate", function()
            local entries = {
                git = { read_only = { { positionals = { "log" } } } },
            }
            local c = PermissionStructured.classify_leaf(
                entries,
                parsed("git", { "log" })
            )
            assert.is_true(c.read_only)
            assert.is_false(c.safe_write)
            assert.is_false(c.ask)
            assert.is_false(c.deny)
        end)

        it("reports safe_write regardless of auto_approve mode", function()
            local entries = {
                git = { safe_write = { { positionals = { "add" } } } },
            }
            local c = PermissionStructured.classify_leaf(
                entries,
                parsed("git", { "add", "x" })
            )
            assert.is_true(c.safe_write)
            assert.is_false(c.read_only)
        end)

        it("reports deny and ask together when both gates fire", function()
            local entries = {
                foo = {
                    deny = { { options = { "force" } } },
                    ask = { { positionals = { "run" } } },
                },
            }
            local c = PermissionStructured.classify_leaf(
                entries,
                parsed("foo", { "run", "--force" })
            )
            assert.is_true(c.deny)
            assert.is_true(c.ask)
        end)

        it("reports nothing for an unknown command", function()
            local c = PermissionStructured.classify_leaf(
                {},
                parsed("frobnicate", { "x" })
            )
            assert.is_false(c.read_only)
            assert.is_false(c.safe_write)
            assert.is_false(c.ask)
            assert.is_false(c.deny)
        end)
    end)

    -- ------------------------------------------------------------------
    -- Concrete-only deny — deny_leaf(entries, parsed)
    -- ------------------------------------------------------------------
    describe("deny_leaf", function()
        local find_deny = { find = { deny = { { options = { "exec" } } } } }

        it("true when a concrete deny gate matches", function()
            assert.is_true(
                PermissionStructured.deny_leaf(
                    find_deny,
                    parsed("find", { ".", "-exec", "rm", "{}" })
                )
            )
        end)

        it("false when no deny gate matches", function()
            assert.is_false(
                PermissionStructured.deny_leaf(
                    find_deny,
                    parsed("find", { ".", "-name", "x" })
                )
            )
        end)

        it("ignores ask gates (only deny rejects)", function()
            assert.is_false(
                PermissionStructured.deny_leaf(
                    { sed = { ask = { { options = { "i" } } } } },
                    parsed("sed", { "-i", "s/a/b/", "f" })
                )
            )
        end)

        -- Concrete-only divergence from decide_leaf: a dynamic flag token
        -- wildcards the deny gate for decide_leaf (escalates to a prompt) but
        -- NOT for deny_leaf (must stay concrete so it falls through to approve).
        describe("dynamic token does not satisfy a deny gate", function()
            local rm_force = { rm = { deny = { { options = { "f", "force" } } } } }
            --- @type agentic.ParsedLeaf
            local dynamic_flag =
                { cmd_name = "rm", args = { "$flags", "x" }, args_dynamic = { true, false } }

            it("decide_leaf wildcards it to deny", function()
                assert.equal(
                    "deny",
                    PermissionStructured.decide_leaf(rm_force, dynamic_flag, "allow")
                )
            end)

            it("deny_leaf stays concrete (false)", function()
                assert.is_false(
                    PermissionStructured.deny_leaf(rm_force, dynamic_flag)
                )
            end)

            it("deny_leaf rejects a concrete -f", function()
                assert.is_true(
                    PermissionStructured.deny_leaf(
                        rm_force,
                        parsed("rm", { "-f", "x" })
                    )
                )
            end)
        end)
    end)
end)
