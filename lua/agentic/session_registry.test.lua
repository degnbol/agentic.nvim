---@diagnostic disable: assign-type-mismatch, need-check-nil, undefined-field, duplicate-set-field
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local MiniTest = require("mini.test")

describe("agentic.SessionRegistry", function()
    --- @type agentic.SessionRegistry
    local SessionRegistry

    --- @type table Mock for SessionManager module
    local session_manager_mock
    --- @type table Stub for Logger module
    local logger_stub
    --- @type table Mock for Config module
    local config_mock

    --- Messages of each `Logger.notify` call
    --- @type string[]
    local notified

    local next_id = 0

    --- @return table mock_session
    local function create_mock_session()
        next_id = next_id + 1
        local session = {
            id = next_id,
            is_mock = true,
        }
        function session:destroy()
            self.destroyed = true
        end
        return session
    end

    session_manager_mock = {
        new = function()
            return create_mock_session()
        end,
    }

    logger_stub = {
        debug = function() end,
        notify = function(message)
            table.insert(notified, message)
        end,
    }

    config_mock = { pi = { command = "true" } }

    local original_loaded = {
        ["agentic.config"] = package.loaded["agentic.config"],
        ["agentic.utils.logger"] = package.loaded["agentic.utils.logger"],
        ["agentic.session_manager"] = package.loaded["agentic.session_manager"],
        ["agentic.session_registry"] = package.loaded["agentic.session_registry"],
    }

    package.loaded["agentic.config"] = config_mock
    package.loaded["agentic.utils.logger"] = logger_stub
    package.loaded["agentic.session_manager"] = session_manager_mock
    package.loaded["agentic.session_registry"] = nil

    SessionRegistry = require("agentic.session_registry")

    for key, value in pairs(original_loaded) do
        package.loaded[key] = value
    end

    before_each(function()
        package.loaded["agentic.session_manager"] = session_manager_mock

        notified = {}
        config_mock.pi = { command = "true" }

        session_manager_mock.new = function()
            return create_mock_session()
        end
    end)

    after_each(function()
        SessionRegistry.by_id = {}
        SessionRegistry.last_active_id = nil

        package.loaded["agentic.session_manager"] =
            original_loaded["agentic.session_manager"]
        package.loaded["agentic.config"] = original_loaded["agentic.config"]
        package.loaded["agentic.utils.logger"] =
            original_loaded["agentic.utils.logger"]
    end)

    --- Register a new mock session.
    --- @return table session
    local function install()
        local session = create_mock_session()
        SessionRegistry.by_id[session.id] = session
        return session
    end

    describe("create", function()
        it("registers and activates a new session", function()
            local session = SessionRegistry.create()

            assert.is_true(session.is_mock)
            assert.equal(session, SessionRegistry.by_id[session.id])
            assert.equal(session.id, SessionRegistry.last_active_id)
        end)

        it("never destroys a live session", function()
            local first = SessionRegistry.create()
            local second = SessionRegistry.create()

            assert.are_not.equal(first, second)
            assert.is_nil(first.destroyed)
            assert.equal(first, SessionRegistry.by_id[first.id])
        end)

        it("returns nil with a notify when pi is not executable", function()
            config_mock.pi = { command = "/nonexistent/pi" }

            assert.is_nil(SessionRegistry.create())
            assert.same({}, SessionRegistry.by_id)
            assert.equal(1, #notified)
            assert.truthy(notified[1]:find("/nonexistent/pi", 1, true))
        end)

        it("returns nil when SessionManager:new returns nil", function()
            session_manager_mock.new = function()
                return nil
            end

            assert.is_nil(SessionRegistry.create())
            assert.same({}, SessionRegistry.by_id)
        end)
    end)

    describe("on_create", function()
        it("runs each listener on a registered session", function()
            local seen = {}
            local unsubscribe = SessionRegistry.on_create(function(session)
                table.insert(seen, {
                    session = session,
                    registered = SessionRegistry.by_id[session.id] == session,
                })
            end)
            MiniTest.finally(unsubscribe)

            local session = SessionRegistry.create()

            assert.same({ { session = session, registered = true } }, seen)
        end)

        it("stops after unsubscribe", function()
            local listener = spy.new(function() end)
            SessionRegistry.on_create(listener --[[@as function]])()

            SessionRegistry.create()

            assert.equal(0, listener.call_count)
        end)

        it("runs no listener when creation fails", function()
            local listener = spy.new(function() end)
            MiniTest.finally(
                SessionRegistry.on_create(listener --[[@as function]])
            )
            session_manager_mock.new = function()
                return nil
            end

            SessionRegistry.create()

            assert.equal(0, listener.call_count)
        end)
    end)

    describe("current", function()
        it("prefers the owner of the current buffer", function()
            local owner = install()
            SessionRegistry.set_active(install())
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.b[bufnr].agentic_session_id = owner.id
            local previous = vim.api.nvim_get_current_buf()
            vim.api.nvim_set_current_buf(bufnr)

            assert.equal(owner, SessionRegistry.current())

            vim.api.nvim_set_current_buf(previous)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("falls back to the last active session", function()
            install()
            local last = install()
            SessionRegistry.set_active(last)

            assert.equal(last, SessionRegistry.current())
        end)

        it("is nil without sessions", function()
            assert.is_nil(SessionRegistry.current())
        end)
    end)

    describe("get_or_create", function()
        it("returns the current session", function()
            local last = install()
            SessionRegistry.set_active(last)

            assert.equal(last, SessionRegistry.get_or_create())
            assert.equal(1, vim.tbl_count(SessionRegistry.by_id))
        end)

        it("creates a session when there is none", function()
            local session = SessionRegistry.get_or_create()

            assert.equal(session, SessionRegistry.by_id[session.id])
        end)
    end)

    describe("destroy", function()
        it("destroys the session and drops it", function()
            local session = install()

            SessionRegistry.destroy(session)

            assert.is_true(session.destroyed)
            assert.is_nil(SessionRegistry.by_id[session.id])
        end)

        it("is a no-op on a session already destroyed", function()
            local session = install()
            local destroy_spy = spy.on(session, "destroy")

            SessionRegistry.destroy(session)
            SessionRegistry.destroy(session)

            assert.spy(destroy_spy).was.called(1)
            destroy_spy:revert()
        end)

        it("still drops a session whose destroy errors", function()
            local session = install()
            session.destroy = function()
                error("destroy failed")
            end

            SessionRegistry.destroy(session)

            assert.is_nil(SessionRegistry.by_id[session.id])
        end)

        it("makes the newest remaining session the last active", function()
            local oldest = install()
            local newest = install()
            local last = install()
            SessionRegistry.set_active(last)

            SessionRegistry.destroy(last)
            assert.equal(newest.id, SessionRegistry.last_active_id)

            SessionRegistry.destroy(newest)
            assert.equal(oldest.id, SessionRegistry.last_active_id)

            SessionRegistry.destroy(oldest)
            assert.is_nil(SessionRegistry.last_active_id)
        end)

        it("picks the newest remaining session, not the oldest", function()
            install()
            local middle = install()
            local newest = install()
            SessionRegistry.set_active(middle)

            SessionRegistry.destroy(middle)

            assert.equal(newest.id, SessionRegistry.last_active_id)
        end)

        it("keeps the last active when another session goes", function()
            local other = install()
            local last = install()
            SessionRegistry.set_active(last)

            SessionRegistry.destroy(other)

            assert.equal(last.id, SessionRegistry.last_active_id)
        end)
    end)

    describe("owner_of_buf", function()
        it("resolves a buffer by its agentic_session_id", function()
            local session = install()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.b[bufnr].agentic_session_id = session.id

            assert.equal(session, SessionRegistry.owner_of_buf(bufnr))

            SessionRegistry.destroy(session)
            assert.is_nil(SessionRegistry.owner_of_buf(bufnr))

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("target_win", function()
        local previous_buf
        local bufnr

        before_each(function()
            previous_buf = vim.api.nvim_get_current_buf()
            bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_set_current_buf(bufnr)
        end)

        after_each(function()
            vim.api.nvim_set_current_buf(previous_buf)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        --- Register a mock session whose widget targets `winid`, owning `bufnr`.
        --- @param winid integer|nil
        --- @return table session
        local function install_owner(winid)
            local session = install()
            session.widget = {
                target_win = function()
                    return winid
                end,
            }
            vim.b[bufnr].agentic_session_id = session.id
            return session
        end

        it("is the current window for a non-Agentic buffer", function()
            assert.equal(
                vim.api.nvim_get_current_win(),
                SessionRegistry.target_win()
            )
        end)

        it("is the current window when the owner is destroyed", function()
            SessionRegistry.destroy(install_owner(nil))

            assert.equal(
                vim.api.nvim_get_current_win(),
                SessionRegistry.target_win()
            )
        end)

        it("is the owner's widget target", function()
            install_owner(nil)
            assert.is_nil(SessionRegistry.target_win())

            install_owner(4242)
            assert.equal(4242, SessionRegistry.target_win())
        end)
    end)
end)
