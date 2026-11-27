local assert = require("tests.helpers.assert")

local SideRecords = require("agentic.ui.side_records")

describe("SideRecords.write", function()
    --- Write `records` to a writer that records each call.
    --- @param records table[] side records, or bare hook records to wrap as one
    --- @return agentic.ui.MessageWriter.HookBlock[] written one per write_hook_block call
    --- @return agentic.acp.LoadedFile[] loaded one per write_loaded_file call
    --- @return agentic.ui.MessageWriter.HookRow[] rows one per write_hook_row call
    --- @return string[] calls the writer methods called, in order
    --- @return agentic.acp.DiscoveredSkills[] skills one per write_discovered_skills call
    local function write(records)
        local sides = vim.tbl_map(function(record)
            return record.kind and record or { kind = "hook", hook = record }
        end, records)
        local written, loaded, rows, calls, skills = {}, {}, {}, {}, {}
        --- @param list table[]
        --- @param method string
        --- @return fun(self: table, arg: table)
        local function record_into(list, method)
            return function(_self, arg)
                table.insert(list, arg)
                table.insert(calls, method)
            end
        end
        local writer = {
            write_hook_block = record_into(written, "write_hook_block"),
            write_hook_row = record_into(rows, "write_hook_row"),
            write_loaded_file = record_into(loaded, "write_loaded_file"),
            write_discovered_skills = record_into(
                skills,
                "write_discovered_skills"
            ),
        }
        SideRecords.write(writer --[[@as agentic.ui.MessageWriter]], sides)
        return written, loaded, rows, calls, skills
    end

    it("sends a loaded file to its writer method", function()
        local file = { path = "/r/a.md", tool_call_id = "toolu_1" }
        local written, loaded = write({
            { kind = "loaded_file", loaded_file = file },
            { group = "context", body = { "ctx" } },
        })

        assert.same({ file }, loaded)
        assert.equal(1, #written)
    end)

    it("sends each kind of a mixed drain to its writer method", function()
        local _, _, _, calls = write({
            {
                kind = "discovered_skills",
                discovered_skills = {
                    title = "New skills",
                    body = { "- foo" },
                    tool_call_id = "toolu_1",
                },
            },
            { kind = "loaded_file", loaded_file = { path = "/r/a.md" } },
            { group = "context", body = { "ctx" } },
        })

        assert.same({
            "write_discovered_skills",
            "write_loaded_file",
            "write_hook_block",
        }, calls)
    end)

    it("forwards a hook record's prompt and compaction anchors", function()
        local written = write({
            { group = "context", body = { "a" }, after_prompt = true },
            { group = "stray", body = { "b" }, after_compaction = true },
        })

        assert.is_true(written[1].after_prompt)
        assert.is_true(written[2].after_compaction)
    end)

    it("forwards a pass's prompt anchor to its row", function()
        local _, _, rows = write({
            { group = "passed", body = {}, command = "/h/a.sh" },
            {
                group = "passed",
                body = {},
                command = "/h/b.sh",
                after_prompt = true,
            },
        })

        assert.equal("`/h/a.sh`", rows[1].text)
        assert.is_nil(rows[1].after_prompt)
        assert.equal("`/h/b.sh`", rows[2].text)
        assert.is_true(rows[2].after_prompt)
    end)

    it("renders injected context", function()
        local written = write({
            { group = "context", body = { "ctx" }, command = "guard.sh" },
        })

        assert.same({
            {
                body = { "ctx" },
                title = "`guard.sh`",
                failed = false,
                for_user = false,
            },
        }, written)
    end)

    it("forwards the tool call the record is anchored to", function()
        local written = write({
            {
                group = "context",
                body = { "ctx" },
                command = "guard.sh",
                tool_call_id = "toolu_01W2Ve",
            },
        })

        assert.equal("toolu_01W2Ve", written[1].tool_call_id)
    end)

    describe("a block's title", function()
        --- The title a context record is written with.
        --- @param record table fields over a context record's
        --- @return string|nil
        local function title_of(record)
            local written = write({
                vim.tbl_extend(
                    "force",
                    { group = "context", body = { "ctx" } },
                    record
                ),
            })
            return written[1].title
        end

        it("is the command as a code span, then the duration", function()
            assert.equal(
                '`sh "$ROOT/init.sh"` · 199 ms',
                title_of({
                    command = 'sh "$ROOT/init.sh"',
                    duration_ms = 199,
                    hook_name = "SessionStart:startup",
                })
            )
        end)

        it("is the command alone when no duration is known", function()
            assert.equal("`guard.sh`", title_of({ command = "guard.sh" }))
        end)

        it("is the hook name when no command is known", function()
            assert.equal(
                "UserPromptSubmit",
                title_of({ hook_name = "UserPromptSubmit" })
            )
        end)

        it("is `hook` when neither is known", function()
            assert.equal("hook", title_of({}))
        end)

        it("joins a multi-line command onto one row", function()
            assert.equal(
                "`cd /r && ./a.sh`",
                title_of({ command = "cd /r &&\n./a.sh" })
            )
        end)

        it("keeps a command holding a backtick one span", function()
            assert.equal(
                "`` echo `date` ``",
                title_of({ command = "echo `date`" })
            )
        end)

        it("is the leading path, the outcome, then the duration", function()
            assert.equal(
                "`/tmp/h/allow.sh` · allowed · 179 ms",
                title_of({
                    command = "/tmp/h/allow.sh --quiet",
                    outcome = "allowed",
                    duration_ms = 179,
                })
            )
        end)

        it("shortens a path under the home directory", function()
            assert.equal(
                "`~/hooks/guard.sh` · blocked",
                title_of({
                    command = vim.env.HOME .. "/hooks/guard.sh",
                    outcome = "blocked",
                })
            )
        end)

        it("shows a relative path verbatim", function()
            assert.equal(
                "`.claude/hooks/x.sh`",
                title_of({ command = ".claude/hooks/x.sh" })
            )
        end)

        it("follows a hook name with the outcome", function()
            assert.equal(
                "PostToolUse:Bash · stopped the turn",
                title_of({ hook_name = "PostToolUse:Bash", outcome = "stopped" })
            )
        end)
    end)

    it("renders a record whose line did not parse", function()
        -- The group exists so an unparseable record cannot vanish.
        local written = write({ { group = "verbatim", body = { "{ trunc" } } })

        assert.equal(1, #written)
        assert.same({ "{ trunc" }, written[1].body)
    end)

    it("marks a failure as failed", function()
        local written = write({
            { group = "failure", body = { "timed out after 600 s" } },
        })

        assert.is_true(written[1].failed)
    end)

    it("renders stray output", function()
        local written = write({ { group = "stray", body = { "leaked" } } })

        assert.equal(1, #written)
        assert.same({ "leaked" }, written[1].body)
        assert.is_false(written[1].failed)
    end)

    it("writes records in the order given", function()
        --- @param command string
        --- @return table
        local function pass(command)
            return {
                group = "passed",
                body = {},
                command = command,
                tool_call_id = "toolu_1",
            }
        end
        local slow = pass("/hooks/lint.sh")
        slow.duration_ms = 2760
        local fast = pass("'/hooks/a guard.sh'")
        fast.duration_ms = 61
        local written, _, rows, calls = write({
            fast,
            { group = "context", body = { "ctx" }, tool_call_id = "toolu_1" },
            slow,
            pass("/hooks/untimed.sh"),
        })

        assert.same({
            "write_hook_row",
            "write_hook_block",
            "write_hook_row",
            "write_hook_row",
        }, calls)
        assert.same({ "ctx" }, written[1].body)
        assert.same({
            {
                text = "`/hooks/a guard.sh` · 61 ms",
                tool_call_id = "toolu_1",
                failed = false,
            },
            {
                text = "`/hooks/lint.sh` · 2.7 s",
                tool_call_id = "toolu_1",
                failed = false,
            },
            {
                text = "`/hooks/untimed.sh`",
                tool_call_id = "toolu_1",
                failed = false,
            },
        }, rows)
    end)

    it("writes a failure with no body as a failed row", function()
        local written, _, rows = write({
            { group = "failure", body = {}, hook_name = "PostToolUse:Write" },
        })

        assert.equal(0, #written)
        assert.same({ { text = "PostToolUse:Write", failed = true } }, rows)
    end)

    it("writes a hook that acted with no body as a row", function()
        local written, _, rows = write({
            {
                group = "context",
                body = {},
                hook_name = "PostToolUse:Bash",
                outcome = "stopped",
            },
        })

        assert.equal(0, #written)
        assert.same({
            { text = "PostToolUse:Bash · stopped the turn", failed = false },
        }, rows)
    end)

    it("flags a message for the user", function()
        local written = write({
            {
                group = "message",
                body = { "SYSMSG-A" },
                hook_name = "PostToolUse:Bash",
            },
        })

        assert.equal(1, #written)
        assert.is_true(written[1].for_user)
        assert.is_false(written[1].failed)
    end)
end)
