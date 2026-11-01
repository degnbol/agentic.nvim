--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local Glyphs = require("agentic.glyphs")
local GrantCommand = require("agentic.grant_command")
local Logger = require("agentic.utils.logger")
local PermissionManager = require("agentic.ui.permission_manager")
local Theme = require("agentic.theme")

describe("agentic.GrantCommand", function()
    describe("resolve_input", function()
        it("resolves `.` and a relative path against the cwd", function()
            assert.equal("/proj", GrantCommand.resolve_input(".", "/proj"))
            assert.equal(
                "/proj/src",
                GrantCommand.resolve_input("src", "/proj")
            )
        end)
    end)

    describe("run", function()
        --- @type TestStub
        local select_stub
        --- @type TestStub
        local input_stub
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local git_root_stub
        --- @type agentic.ui.PermissionManager
        local permission_manager
        --- @type agentic.GrantCommand
        local grants
        --- @type agentic.ui.MessageWriter.Notice[]
        local notices
        --- @type any[]
        local errors
        --- Resolved temp dir standing in for the session cwd's git root.
        --- @type string
        local repo
        --- @type string
        local cwd
        --- @type boolean
        local mid_turn
        local orig_defaults

        --- @return string[] keys The active grant scope keys, in order
        local function grant_keys()
            return vim.tbl_map(function(scope)
                return scope.key
            end, permission_manager:get_grant_scopes())
        end

        --- @param needle string
        --- @return integer count WARN notifications whose message contains `needle`
        local function warn_count(needle)
            local count = 0
            for _, c in ipairs(notify_stub.calls) do
                if
                    c[2] == vim.log.levels.WARN
                    and c[1]:find(needle, 1, true)
                then
                    count = count + 1
                end
            end
            return count
        end

        before_each(function()
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir .. "/sub", "p")
            repo = vim.uv.fs_realpath(dir) --[[@as string]]
            cwd = repo .. "/sub"
            mid_turn = false

            select_stub = spy.stub(vim.ui, "select")
            input_stub = spy.stub(vim.ui, "input")
            notify_stub = spy.stub(Logger, "notify")
            git_root_stub = spy.stub(vim.fs, "root")
            git_root_stub:returns(repo)

            orig_defaults = Config.permissions.default_grant

            notices = {}
            errors = {}

            permission_manager = {
                _grant_scopes = {},
                add_grant_scope = PermissionManager.add_grant_scope,
                remove_grant_scope = PermissionManager.remove_grant_scope,
                clear_grant_scopes = PermissionManager.clear_grant_scopes,
                get_grant_scopes = PermissionManager.get_grant_scopes,
            } --[[@as agentic.ui.PermissionManager]]
            grants = GrantCommand:new(permission_manager, {
                write_notice = spy.new(function(_, notice)
                    table.insert(notices, notice)
                end),
                write_error_action = spy.new(function(_, msg)
                    table.insert(errors, msg)
                end),
            } --[[@as agentic.ui.MessageWriter]], function()
                return cwd
            end, function()
                return mid_turn
            end)
        end)

        after_each(function()
            select_stub:revert()
            input_stub:revert()
            notify_stub:revert()
            git_root_stub:revert()
            Config.permissions.default_grant = orig_defaults
            vim.fs.rm(repo, { recursive = true, force = true })
        end)

        it("`.` grants the session cwd and confirms in the chat", function()
            grants:run(".")
            assert.same({ repo .. "/sub" }, grant_keys())
            assert.equal(".", notices[1].title)
            assert.equal(Glyphs.COMMAND.grant, notices[1].glyph)
            assert.is_nil(notices[1].glyph_hl)
        end)

        it("grants combine", function()
            grants:run("root")
            grants:run(".")
            assert.same({ repo, repo .. "/sub" }, grant_keys())
        end)

        it("re-adding a grant only reports it", function()
            grants:run(".")
            grants:run("./")
            assert.equal(1, #grant_keys())
            assert.equal("already granted: ./", notices[2].title)
        end)

        it("nests the notice in the turn it widens", function()
            -- A scope added mid-turn governs the tool calls after it, so it
            -- renders inside the running turn rather than at the boundary.
            mid_turn = true
            grants:run(".")
            assert.is_true(notices[1].mid_turn)
        end)

        it("off clears every grant", function()
            grants:run(".")
            grants:run("off")
            assert.equal(0, #grant_keys())
            -- The cleared notice reuses the add glyph, struck through.
            assert.equal(Glyphs.COMMAND.grant, notices[2].glyph)
            assert.equal(Theme.HL_GROUPS.GLYPH_OFF, notices[2].glyph_hl)
        end)

        it("a relative glob resolves against the session cwd", function()
            grants:run("src/**/*.lua")
            assert.same({ repo .. "/sub/src/**/*.lua" }, grant_keys())
            assert.equal("src/**/*.lua", notices[1].title)
        end)

        it("root without a git root errors", function()
            git_root_stub:returns(nil)
            grants:run("root")
            assert.equal(0, #grant_keys())
            assert.equal(1, #errors)
        end)

        it("warns for a wide grant, not for a tmp root", function()
            grants:run("/")
            assert.equal(1, warn_count("Wide grant"))
            grants:run("/tmp")
            assert.equal(1, warn_count("Wide grant"))
        end)

        it("adds a missing path and warns", function()
            grants:run("typo/dir")
            assert.same({ repo .. "/sub/typo/dir" }, grant_keys())
            assert.equal(1, warn_count("does not exist yet"))
        end)

        describe("picker", function()
            --- @return { label: string }[] items
            --- @return fun(item: table|nil) on_choice
            local function open_picker()
                grants:run("")
                local call = select_stub.calls[select_stub.call_count]
                return call[1], call[3]
            end

            it("toggles `.`, `root` and active grants", function()
                grants:run("/tmp")
                grants:run(".")
                local items, on_choice = open_picker()
                local labels = vim.tbl_map(function(item)
                    return item.label
                end, items)
                assert.is_true(vim.startswith(labels[1], "✓ . ("))
                assert.is_true(vim.startswith(labels[2], "root ("))
                assert.equal("✓ /tmp", labels[3])
                assert.same(
                    { "Path or glob…", "Off" },
                    { labels[4], labels[5] }
                )

                on_choice(items[1])
                assert.same({ "/tmp" }, grant_keys())
                assert.equal("grant removed: .", notices[#notices].title)

                on_choice(items[2])
                assert.same({ "/tmp", repo }, grant_keys())
            end)

            it("lists root once when it is the cwd", function()
                cwd = repo
                local items = open_picker()
                assert.equal(3, #items)
            end)
        end)

        describe("apply_defaults", function()
            it("adds silently", function()
                Config.permissions.default_grant = { "/tmp", "." }
                grants:apply_defaults()
                assert.same({ "/tmp", repo .. "/sub" }, grant_keys())
                assert.equal(0, #notices)
                assert.equal(0, warn_count(""))
            end)

            it(
                "skips an unset variable and warns for a missing path",
                function()
                    Config.permissions.default_grant = {
                        "$AGENTIC_UNSET_VAR",
                        "$AGENTIC_UNSET_VAR/sub",
                        "/nonexistent-agentic-root",
                    }
                    grants:apply_defaults()
                    assert.same({ "/nonexistent-agentic-root" }, grant_keys())
                    assert.equal(1, warn_count("does not exist yet"))
                end
            )
        end)
    end)
end)
