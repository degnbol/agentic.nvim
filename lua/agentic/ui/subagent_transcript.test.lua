local assert = require("tests.helpers.assert")
local Config = require("agentic.config")

describe("agentic.ui.SubagentTranscript", function()
    local ChatWidget = require("agentic.ui.chat_widget")
    local SubagentTranscript = require("agentic.ui.subagent_transcript")

    --- @type agentic.ui.ChatWidget
    local widget
    --- @type agentic.ui.SubagentTranscript[]
    local transcripts
    --- @type table<string, integer>
    local calls

    --- @type agentic.ui.MessageWriter.SubagentInfo
    local info = { label = "map the UI", mode = "background", confirmed = false }

    -- One per test: a destroyed widget's chat keeps its name until the next
    -- tick.
    local owner_id = 4241

    before_each(function()
        owner_id = owner_id + 1
        widget = ChatWidget:new(owner_id, function()
            return true
        end)
        transcripts = {}
        calls = { setup_buf = 0, on_reload = 0, on_write = 0, on_wipeout = 0 }
    end)

    after_each(function()
        for _, transcript in ipairs(transcripts) do
            transcript:destroy()
        end
        widget:destroy()
    end)

    --- @param agent_id string
    --- @param generation integer|nil 1 when nil
    --- @return agentic.ui.SubagentTranscript
    local function new_transcript(agent_id, generation)
        --- @type agentic.ui.SubagentTranscript
        local transcript
        transcript = SubagentTranscript:new(agent_id, generation or 1, info, widget, {
            setup_buf = function()
                calls.setup_buf = calls.setup_buf + 1
            end,
            on_reload = function()
                calls.on_reload = calls.on_reload + 1
                transcript:restart(info)
            end,
            on_write = function()
                calls.on_write = calls.on_write + 1
            end,
            on_wipeout = function()
                calls.on_wipeout = calls.on_wipeout + 1
            end,
        })
        table.insert(transcripts, transcript)
        return transcript
    end

    --- Run an Ex command in a window of a new tabpage showing `bufnr`.
    --- @param bufnr integer
    --- @param command string|nil
    --- @param check fun()|nil Runs in that window after the command
    local function in_window(bufnr, command, check)
        vim.cmd("tabnew")
        local scratch = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_buf(0, bufnr)
        if command then
            vim.cmd(command)
        end
        if check then
            check()
        end
        vim.cmd("tabclose")
        vim.api.nvim_buf_delete(scratch, { force = true })
    end

    --- @param bufnr integer
    --- @return string[]
    local function lines_of(bufnr)
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    it("is named after the agent id's tail and the label", function()
        local transcript = new_transcript("aa11bb22cc33dd44")
        local name = vim.api.nvim_buf_get_name(transcript.bufnr)

        assert.equal(
            ("agentic://%d/subagent/cc33dd44-map-the-UI"):format(owner_id),
            name
        )
        assert.is_nil(name:find("%s"))
    end)

    it("names a later generation apart", function()
        new_transcript("aa11bb22cc33dd44")
        local second = new_transcript("aa11bb22cc33dd44", 2)

        assert.equal(
            ("agentic://%d/subagent/cc33dd44-g2-map-the-UI"):format(owner_id),
            vim.api.nvim_buf_get_name(second.bufnr)
        )
    end)

    it("opens with gf from any column of its name", function()
        local transcript = new_transcript("aa11bb22cc33dd44", 2)
        local name = vim.api.nvim_buf_get_name(transcript.bufnr)
        local scratch = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { name })
        vim.cmd("tabnew")
        local winid = vim.api.nvim_get_current_win()

        for _, col in ipairs({ 0, #name - 1 }) do
            vim.api.nvim_win_set_buf(winid, scratch)
            vim.api.nvim_win_set_cursor(winid, { 1, col })
            vim.cmd("normal! gf")
            assert.equal(transcript.bufnr, vim.api.nvim_win_get_buf(winid))
        end

        vim.cmd("tabclose")
        vim.api.nvim_buf_delete(scratch, { force = true })
    end)

    it("opens with its heading", function()
        local transcript = new_transcript("aa11bb22cc33dd44")

        assert.equal("## Background? map the UI", lines_of(transcript.bufnr)[1])
    end)

    it("writes its heading again on :e", function()
        local transcript = new_transcript("aa11bb22cc33dd44")
        transcript:set_modified(false)
        in_window(transcript.bufnr, "edit")

        assert.equal(1, calls.on_reload)
        assert.equal("## Background? map the UI", lines_of(transcript.bufnr)[1])
    end)

    it("has the panel's b-vars and maps at creation and after :e", function()
        local transcript = new_transcript("aa11bb22cc33dd44")
        local bufnr = transcript.bufnr

        --- @return boolean
        local function has_goto_bottom_map()
            local map = vim.fn.maparg(
                Config.keymaps.widget.goto_bottom,
                "n",
                false,
                true
            )
            return map.buffer == 1
        end

        local function check()
            assert.equal(owner_id, vim.b[bufnr].agentic_session_id)
            assert.equal("subagent", vim.b[bufnr].agentic_window)
            assert.equal("acwrite", vim.bo[bufnr].buftype)
            assert.is_true(has_goto_bottom_map())
        end

        in_window(bufnr, nil, check)
        assert.equal(1, calls.setup_buf)
        transcript:set_modified(false)
        in_window(bufnr, "edit", check)
        assert.equal(2, calls.setup_buf)
    end)

    it("writes the session on :w", function()
        local transcript = new_transcript("aa11bb22cc33dd44")
        in_window(transcript.bufnr, "write")

        assert.equal(1, calls.on_write)
    end)

    it("replays only its own agent on :e!", function()
        local first = new_transcript("aa11bb22cc33dd44")
        new_transcript("ee55ff66aa77bb88")
        in_window(first.bufnr, "edit!")

        assert.equal(1, calls.on_reload)
    end)

    it("is unlisted by :bd and stays valid", function()
        local transcript = new_transcript("aa11bb22cc33dd44")
        vim.cmd.bdelete({ args = { transcript.bufnr }, bang = true })

        assert.is_true(vim.api.nvim_buf_is_valid(transcript.bufnr))
        assert.is_false(vim.bo[transcript.bufnr].buflisted)
    end)

    it("reports a wipeout, but not its own destroy", function()
        local wiped = new_transcript("aa11bb22cc33dd44")
        vim.cmd.bwipeout({ args = { wiped.bufnr }, bang = true })
        assert.equal(1, calls.on_wipeout)

        new_transcript("ee55ff66aa77bb88"):destroy()
        assert.equal(1, calls.on_wipeout)
    end)

    it("sets 'modified' only while loaded", function()
        local transcript = new_transcript("aa11bb22cc33dd44")
        transcript:set_modified(true)
        assert.is_true(vim.bo[transcript.bufnr].modified)

        vim.cmd.bunload({ args = { transcript.bufnr }, bang = true })
        transcript:set_modified(true)
        assert.is_false(vim.api.nvim_buf_is_loaded(transcript.bufnr))
    end)

    it("shows the heading and state in its header", function()
        local transcript = new_transcript("aa11bb22cc33dd44")
        transcript:set_header(info, "completed")

        local header = vim.b[transcript.bufnr].agentic_header
        assert.is_true(header.title:find("Background? map the UI", 1, true) ~= nil)
        assert.equal("completed", header.context)
    end)
end)
