local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- Lua run in each child: a throwaway session store, three project dirs and
--- `_G.dir_of`, the editor cwd after a `:cd` into one of them.
local SETUP = [[
require("agentic.config").session_restore.storage_path = vim.fn.tempname()
_G.ChatHistory = require("agentic.ui.chat_history")
_G.dirs = {}
_G.dir_of = {}
for _, name in ipairs({ "A", "B", "C" }) do
    _G.dirs[name] = vim.fn.tempname()
    vim.fn.mkdir(_G.dirs[name], "p")
    vim.cmd.cd(_G.dirs[name])
    _G.dir_of[name] = vim.fn.getcwd()
end

--- Give session `s` the id `id`, and store its session/load callback in
--- `_G.load_cb`.
_G.bind = function(s, id)
    s.session_id = id
    s.chat_history.session_id = id
    s.agent.agent_capabilities = { loadSession = true }
    s.agent._send_request = function(_, method, _, cb)
        if method == "session/load" then _G.load_cb = cb end
    end
    return s
end

--- Add a user message to `s` and let it save.
_G.say = function(s, text)
    s.chat_history:add_message({
        type = "user", text = text, timestamp = os.time(), provider_name = "p",
    })
    s:_history_changed(s.chat_history)
end

--- The decoded session file of `id` in the project folder of `cwd`, or nil.
_G.file = function(id, cwd)
    local path = _G.ChatHistory.get_file_path(id, cwd)
    if not vim.uv.fs_stat(path) then return nil end
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end
]]

describe("session files follow the session's cwd", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
    end)

    after_each(function()
        child.stop()
    end)

    it("keeps each session's file in its own folder after a :cd", function()
        child.lua([[
vim.cmd.cd(_G.dirs.A)
vim.cmd("Agentic")
]])
        child.flush()
        child.lua([[
_G.a = require("agentic.session_registry").current()
vim.cmd.cd(_G.dirs.B)
require("agentic").new_session()
]])
        child.flush()
        child.lua([[
_G.b = _G.bind(require("agentic.session_registry").current(), "sid-b")
_G.bind(_G.a, "sid-a")
vim.cmd.cd(_G.dirs.C)
_G.say(_G.a, "in A")
_G.say(_G.b, "in B")
]])

        assert.equal(
            child.lua_get("_G.dir_of.A"),
            child.lua_get([[_G.file("sid-a", _G.dir_of.A).cwd]])
        )
        assert.equal(
            child.lua_get("_G.dir_of.B"),
            child.lua_get([[_G.file("sid-b", _G.dir_of.B).cwd]])
        )
        assert.is_false(
            child.lua_get(
                [[vim.uv.fs_stat(_G.ChatHistory.get_sessions_folder(_G.dir_of.C)) ~= nil]]
            )
        )
    end)

    for _, load_cwd in ipairs({ "_G.dirs.A", "nil" }) do
        it(
            "loads a session of another project and saves back to it, cwd "
                .. load_cwd,
            function()
                child.lua([[
local saved = _G.ChatHistory:new()
saved.session_id = "sid-x"
saved:set_title("From A")
assert(saved:save(_G.dir_of.A) == nil)
vim.cmd.cd(_G.dirs.C)
vim.cmd("Agentic")
]])
                child.flush()
                child.lua(([[
_G.s = _G.bind(require("agentic.session_registry").current(), "root")
_G.s:_do_load_acp_session("sid-x", %s)
]]):format(load_cwd))

                assert.equal("From A", child.lua_get("_G.s.chat_history.title"))
                assert.equal(
                    child.lua_get("_G.dir_of.A"),
                    child.lua_get("_G.s._cwd")
                )

                child.lua([[_G.load_cb({}, nil)]])
                child.flush()
                child.lua([[_G.say(_G.s, "after load")]])

                assert.equal(
                    "after load",
                    child.lua_get(
                        [[_G.file("sid-x", _G.dir_of.A).messages[1].text]]
                    )
                )
                assert.is_true(
                    child.lua_get([[_G.file("sid-x", _G.dir_of.C) == nil]])
                )
            end
        )
    end

    it("loads a legacy file with no cwd from another project", function()
        child.lua([[
local path = _G.ChatHistory.get_file_path("sid-old", _G.dir_of.A)
vim.fn.mkdir(vim.fs.dirname(path), "p")
vim.fn.writefile({ vim.json.encode({
    session_id = "sid-old", title = "Legacy", timestamp = 0, messages = {},
}) }, path)
vim.cmd.cd(_G.dirs.C)
vim.cmd("Agentic")
]])
        child.flush()
        child.lua([[
_G.s = _G.bind(require("agentic.session_registry").current(), "root")
_G.s:_do_load_acp_session("sid-old", nil)
]])

        assert.equal("Legacy", child.lua_get("_G.s.chat_history.title"))
        assert.equal(child.lua_get("_G.dir_of.C"), child.lua_get("_G.s._cwd"))
    end)

    it("canonicalises the load cwd", function()
        child.lua([[vim.cmd("Agentic")]])
        child.flush()
        child.lua([[
_G.s = _G.bind(require("agentic.session_registry").current(), "root")
_G.s:_do_load_acp_session("sid-y", _G.dirs.A .. "/")
]])

        assert.equal(child.lua_get("_G.dir_of.A"), child.lua_get("_G.s._cwd"))
    end)

    it("starts a new session in the cwd it was opened in", function()
        child.lua([[
vim.cmd.cd(_G.dirs.A)
vim.cmd("Agentic")
_G.s = require("agentic.session_registry").current()
vim.cmd.cd(_G.dirs.B)
]])
        child.flush()

        assert.equal(child.lua_get("_G.dir_of.A"), child.lua_get("_G.s._cwd"))
    end)
end)
