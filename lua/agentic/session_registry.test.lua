---@diagnostic disable: assign-type-mismatch, need-check-nil, undefined-field, duplicate-set-field
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.SessionRegistry", function()
    --- @type agentic.SessionRegistry
    local SessionRegistry

    --- @type table Mock for SessionManager module
    local session_manager_mock
    --- @type table Mock for ACPHealth module
    local acp_health_mock
    --- @type table Stub for Logger module
    local logger_stub
    --- @type table Mock for Config module
    local config_mock
    --- @type table Mock for DefaultConfig module
    local default_config_mock

    --- @type TestStub|nil
    local ui_select_stub

    local next_id = 0

    --- @return table mock_session
    local function create_mock_session()
        next_id = next_id + 1
        local session = { id = next_id, is_mock = true }
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

    acp_health_mock = {
        check_configured_provider = function()
            return true
        end,
        get_default_provider_names = function()
            return {}
        end,
        is_command_available = function()
            return false
        end,
    }

    logger_stub = {
        debug = function() end,
        notify = function() end,
    }

    config_mock = {
        provider = "claude-agent-acp",
        acp_providers = {
            ["claude-agent-acp"] = { command = "claude-agent-acp" },
            ["gemini-acp"] = { command = "gemini" },
        },
    }

    default_config_mock = {
        provider = "claude-agent-acp",
    }

    local original_loaded = {
        ["agentic.config"] = package.loaded["agentic.config"],
        ["agentic.config_default"] = package.loaded["agentic.config_default"],
        ["agentic.acp.acp_health"] = package.loaded["agentic.acp.acp_health"],
        ["agentic.utils.logger"] = package.loaded["agentic.utils.logger"],
        ["agentic.session_manager"] = package.loaded["agentic.session_manager"],
        ["agentic.session_registry"] = package.loaded["agentic.session_registry"],
    }

    package.loaded["agentic.config"] = config_mock
    package.loaded["agentic.config_default"] = default_config_mock
    package.loaded["agentic.acp.acp_health"] = acp_health_mock
    package.loaded["agentic.utils.logger"] = logger_stub
    package.loaded["agentic.session_manager"] = session_manager_mock
    package.loaded["agentic.session_registry"] = nil

    SessionRegistry = require("agentic.session_registry")

    for key, value in pairs(original_loaded) do
        package.loaded[key] = value
    end

    before_each(function()
        package.loaded["agentic.session_manager"] = session_manager_mock

        acp_health_mock.check_configured_provider = function()
            return true
        end
        acp_health_mock.get_default_provider_names = function()
            return {}
        end
        acp_health_mock.is_command_available = function()
            return false
        end

        config_mock.provider = "claude-agent-acp"
        config_mock.acp_providers = {
            ["claude-agent-acp"] = { command = "claude-agent-acp" },
            ["gemini-acp"] = { command = "gemini" },
        }
        default_config_mock.provider = "claude-agent-acp"

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
        package.loaded["agentic.config_default"] =
            original_loaded["agentic.config_default"]
        package.loaded["agentic.acp.acp_health"] =
            original_loaded["agentic.acp.acp_health"]
        package.loaded["agentic.utils.logger"] =
            original_loaded["agentic.utils.logger"]

        if ui_select_stub then
            ui_select_stub:revert()
            ui_select_stub = nil
        end
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

        it("returns nil when no provider is configured", function()
            acp_health_mock.check_configured_provider = function()
                return false
            end

            assert.is_nil(SessionRegistry.create())
            assert.same({}, SessionRegistry.by_id)
        end)

        it("returns nil when SessionManager:new returns nil", function()
            session_manager_mock.new = function()
                return nil
            end

            assert.is_nil(SessionRegistry.create())
            assert.same({}, SessionRegistry.by_id)
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

    describe("select_provider", function()
        --- @type table[]|nil
        local captured_items
        --- @type table|nil
        local captured_opts
        --- @type function|nil
        local captured_on_choice

        before_each(function()
            captured_items = nil
            captured_opts = nil
            captured_on_choice = nil

            ui_select_stub = spy.stub(vim.ui, "select")
            ui_select_stub:invokes(function(items, opts, on_choice)
                captured_items = items
                captured_opts = opts
                captured_on_choice = on_choice
            end)
        end)

        it("sorts installed providers before not-installed", function()
            acp_health_mock.get_default_provider_names = function()
                return { "claude-agent-acp", "gemini-acp" }
            end
            acp_health_mock.is_command_available = function(cmd)
                return cmd == "gemini"
            end

            SessionRegistry.select_provider(function() end)

            assert.is_not_nil(captured_items)
            assert.equal(2, #captured_items)
            assert.equal("gemini-acp", captured_items[1].name)
            assert.is_true(captured_items[1].installed)
            assert.equal("claude-agent-acp", captured_items[2].name)
            assert.is_false(captured_items[2].installed)
        end)

        it("marks provider without config as not-installed", function()
            acp_health_mock.get_default_provider_names = function()
                return { "unknown-acp" }
            end

            SessionRegistry.select_provider(function() end)

            assert.equal(1, #captured_items)
            assert.equal("unknown-acp", captured_items[1].name)
            assert.is_false(captured_items[1].installed)
        end)

        it("calls on_selected with provider name on selection", function()
            acp_health_mock.get_default_provider_names = function()
                return { "claude-agent-acp" }
            end

            local result = nil
            SessionRegistry.select_provider(function(name)
                result = name
            end)

            captured_on_choice({ name = "claude-agent-acp", installed = true })

            assert.equal("claude-agent-acp", result)
        end)

        it("calls on_selected with nil on cancellation", function()
            acp_health_mock.get_default_provider_names = function()
                return { "claude-agent-acp" }
            end

            local called = false
            local result = nil
            SessionRegistry.select_provider(function(name)
                called = true
                result = name
            end)

            captured_on_choice(nil)

            assert.is_true(called)
            assert.is_nil(result)
        end)

        describe("format_item labels", function()
            before_each(function()
                acp_health_mock.get_default_provider_names = function()
                    return { "claude-agent-acp", "gemini-acp" }
                end
                acp_health_mock.is_command_available = function(cmd)
                    return cmd == "claude-agent-acp"
                end
            end)

            it("appends '(current)' for Config.provider", function()
                config_mock.provider = "claude-agent-acp"
                default_config_mock.provider = "gemini-acp"

                SessionRegistry.select_provider(function() end)

                local label = captured_opts.format_item({
                    name = "claude-agent-acp",
                    installed = true,
                })
                assert.equal("claude-agent-acp (current) ✓ available", label)
            end)

            it(
                "appends '(default)' for DefaultConfig.provider when not current",
                function()
                    config_mock.provider = "gemini-acp"
                    default_config_mock.provider = "claude-agent-acp"

                    SessionRegistry.select_provider(function() end)

                    local label = captured_opts.format_item({
                        name = "claude-agent-acp",
                        installed = true,
                    })
                    assert.equal(
                        "claude-agent-acp (default) ✓ available",
                        label
                    )
                end
            )

            it("appends availability suffix based on installed flag", function()
                config_mock.provider = "none"
                default_config_mock.provider = "none"

                SessionRegistry.select_provider(function() end)

                local installed_label = captured_opts.format_item({
                    name = "claude-agent-acp",
                    installed = true,
                })
                local missing_label = captured_opts.format_item({
                    name = "gemini-acp",
                    installed = false,
                })

                assert.equal("claude-agent-acp ✓ available", installed_label)
                assert.equal("gemini-acp ✗ not installed", missing_label)
            end)

            it(
                "prefers '(current)' over '(default)' when both match",
                function()
                    config_mock.provider = "claude-agent-acp"
                    default_config_mock.provider = "claude-agent-acp"

                    SessionRegistry.select_provider(function() end)

                    local label = captured_opts.format_item({
                        name = "claude-agent-acp",
                        installed = true,
                    })
                    assert.equal(
                        "claude-agent-acp (current) ✓ available",
                        label
                    )
                end
            )
        end)
    end)
end)
