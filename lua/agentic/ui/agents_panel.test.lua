--- @diagnostic disable: invisible, missing-fields
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentsPanel = require("agentic.ui.agents_panel")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

--- @type agentic.ui.MessageWriter.SubagentInfo
local info = { label = "map UI", mode = "blocking", confirmed = true }

--- @param child_id string
--- @param state string
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil Default `info`
--- @return agentic.Subagents.Entry
local function entry(child_id, state, subagent)
    --- @type agentic.Subagents.Entry
    local e = {
        child_id = child_id,
        state = state,
        subagent = subagent or info,
        name = "agentic://c1/subagent/" .. child_id,
    }
    return e
end

describe("agentic.ui.AgentsPanel", function()
    describe("lines", function()
        it("aligns state, mode, type, name and label", function()
            assert.same(
                {
                    "working    Blocking?   Explore        agentic://c1/subagent/a  Map UI",
                    "completed  Background  code-reviewer  agentic://c1/subagent/b  Review",
                },
                AgentsPanel.lines({
                    entry("a", "working", {
                        mode = "blocking",
                        confirmed = false,
                        agent_type = "Explore",
                        label = "Map UI",
                    }),
                    entry("b", "completed", {
                        mode = "background",
                        confirmed = true,
                        agent_type = "code-reviewer",
                        label = "Review",
                    }),
                })
            )
        end)

        it("labels an entry without a block `Agent`", function()
            local e = entry("a", "ended")
            e.subagent = nil
            assert.same(
                {
                    "ended                       agentic://c1/subagent/a  Agent",
                    "working  Blocking  Explore  agentic://c1/subagent/b  map UI",
                },
                AgentsPanel.lines({
                    e,
                    entry("b", "working", {
                        mode = "blocking",
                        confirmed = true,
                        agent_type = "Explore",
                        label = "map UI",
                    }),
                })
            )
        end)

        it("drops the type column while no entry has a type", function()
            assert.same(
                {
                    "working    Blocking  agentic://c1/subagent/a  map UI",
                    "completed  Blocking  agentic://c1/subagent/b  map UI",
                },
                AgentsPanel.lines({
                    entry("a", "working"),
                    entry("b", "completed"),
                })
            )
        end)
    end)

    describe("keys", function()
        local owner_id = 9301
        --- @type integer
        local bufnr
        --- @type agentic.ui.AgentsPanel
        local panel
        --- @type TestSpy
        local open
        --- @type TestStub
        local notify_stub
        --- Listed transcripts by child id.
        --- @type table<string, integer>
        local transcripts

        before_each(function()
            owner_id = owner_id + 1
            bufnr = vim.api.nvim_create_buf(false, true)
            vim.b[bufnr].agentic_session_id = owner_id
            transcripts = {}
            for _, id in ipairs({ "a", "b", "c" }) do
                transcripts[id] = vim.api.nvim_create_buf(true, true)
            end
            open = spy.new(function() end)
            panel = AgentsPanel:new(function()
                return bufnr
            end, {
                buf_of = function(child_id)
                    return transcripts[child_id]
                end,
                open = open --[[@as fun(child_id: string)]],
            })
            SessionRegistry.by_id[owner_id] = { agents_panel = panel } --[[@as agentic.SessionManager]]
            panel:bind_keymaps(bufnr)
            panel:render({
                entry("a", "completed"),
                entry("b", "working"),
                entry("c", "failed"),
            })
            vim.cmd("tabnew")
            vim.api.nvim_win_set_buf(0, bufnr)
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
            SessionRegistry.by_id[owner_id] = nil
            vim.cmd("tabonly")
            vim.api.nvim_buf_delete(bufnr, { force = true })
            for _, transcript in pairs(transcripts) do
                vim.api.nvim_buf_delete(transcript, { force = true })
            end
        end)

        --- The child ids whose transcript is no longer listed, sorted.
        --- @return string[]
        local function deleted()
            local ids = vim.tbl_filter(function(id)
                return not vim.bo[transcripts[id]].buflisted
            end, vim.tbl_keys(transcripts))
            table.sort(ids)
            return ids
        end

        it("deletes the row under the cursor with dd", function()
            vim.cmd("normal dd")
            assert.same({ "a" }, deleted())
            assert.is_false(vim.api.nvim_buf_is_loaded(transcripts.a))
        end)

        it("deletes the rows of a motion", function()
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            vim.cmd("normal dj")
            assert.same({ "c" }, deleted())
            assert.equal(1, notify_stub.call_count)
            assert.truthy(notify_stub.calls[1][1]:find("map UI", 1, true))
        end)

        it("deletes a visual selection", function()
            vim.cmd("normal Vjjd")
            assert.same({ "a", "c" }, deleted())
        end)

        it("keeps a working row and names it", function()
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            vim.cmd("normal dd")
            assert.same({}, deleted())
            assert.equal(1, notify_stub.call_count)
        end)

        it("notifies a transcript that refuses the delete", function()
            vim.bo[transcripts.a].buftype = "acwrite"
            vim.bo[transcripts.a].modified = true

            vim.cmd("normal dd")

            assert.same({}, deleted())
            assert.equal(1, notify_stub.call_count)
            assert.equal(vim.log.levels.ERROR, notify_stub.calls[1][2])
        end)

        it("opens the row's transcript with gf and <CR>", function()
            vim.api.nvim_win_set_cursor(0, { 3, 0 })
            vim.cmd("normal gf")
            vim.cmd('execute "normal \\<CR>"')
            assert.equal(2, open.call_count)
            assert.equal("c", open.calls[1][1])
            assert.equal("c", open.calls[2][1])
        end)

        it("does nothing in a buffer of no session", function()
            SessionRegistry.by_id[owner_id] = nil
            vim.cmd("normal dd")
            assert.same({}, deleted())
        end)
    end)

    describe("render", function()
        it("writes the rows and writes nothing without a buffer", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            --- @type integer|nil
            local target = bufnr
            local panel = AgentsPanel:new(function()
                return target
            end, {
                buf_of = function() end,
                open = function() end,
            })

            panel:render({ entry("a", "working") })
            assert.same(
                AgentsPanel.lines({ entry("a", "working") }),
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )

            target = nil
            panel:render({})
            assert.equal(1, #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)
end)
