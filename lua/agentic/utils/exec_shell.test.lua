local assert = require("tests.helpers.assert")
local ExecShell = require("agentic.utils.exec_shell")
local Config = require("agentic.config")

describe("ExecShell", function()
    local orig_shell
    local orig_code_shell
    local orig_provider
    local orig_env

    before_each(function()
        orig_shell = vim.env.SHELL
        orig_code_shell = vim.env.CLAUDE_CODE_SHELL
        orig_provider = Config.provider
        orig_env = Config.acp_providers["claude-agent-acp"].env
        Config.provider = "claude-agent-acp"
        Config.acp_providers["claude-agent-acp"].env = {}
        vim.env.SHELL = nil
        vim.env.CLAUDE_CODE_SHELL = nil
    end)

    after_each(function()
        vim.env.SHELL = orig_shell
        vim.env.CLAUDE_CODE_SHELL = orig_code_shell
        Config.acp_providers["claude-agent-acp"].env = orig_env
        Config.provider = orig_provider
    end)

    describe("resolve", function()
        it("prefers CLAUDE_CODE_SHELL over SHELL", function()
            vim.env.CLAUDE_CODE_SHELL = "/bin/zsh"
            vim.env.SHELL = "/bin/bash"
            assert.equal("zsh", ExecShell.resolve())
        end)

        it("falls back to SHELL when no override", function()
            vim.env.SHELL = "/bin/bash"
            assert.equal("bash", ExecShell.resolve())
        end)

        it("returns nil for a SHELL naming an unknown shell", function()
            vim.env.SHELL = "/usr/bin/fish"
            assert.is_nil(ExecShell.resolve())
        end)

        it("returns nil when SHELL is unset and no override", function()
            assert.is_nil(ExecShell.resolve())
        end)

        it(
            "reads the provider env override, not raw vim.env",
            function()
                -- The child runs bash because the provider config overlays
                -- SHELL=/bin/bash, even though vim.env.SHELL is still zsh.
                vim.env.SHELL = "/bin/zsh"
                Config.acp_providers[Config.provider].env =
                    { SHELL = "/bin/bash" }
                assert.equal("bash", ExecShell.resolve())
            end
        )
    end)
end)
