--- @alias agentic.UserConfig.ProviderName
--- | "claude-acp"
--- | "claude-agent-acp"
--- | "gemini-acp"
--- | "codex-acp"
--- | "opencode-acp"
--- | "cursor-acp"
--- | "auggie-acp"
--- | "mistral-vibe-acp"

--- @alias agentic.UserConfig.HeaderRenderFn fun(parts: agentic.ui.ChatWidget.HeaderParts): string|nil

--- User config headers - each panel can have either config parts or a custom render function
--- @alias agentic.UserConfig.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts|agentic.UserConfig.HeaderRenderFn|nil>

--- Data passed to the on_prompt_submit hook
--- @class agentic.UserConfig.PromptSubmitData
--- @field prompt string The user's prompt text
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID

--- Data passed to the on_response_complete hook
--- @class agentic.UserConfig.ResponseCompleteData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field success boolean Whether response completed without error
--- @field error? table Error details if failed

--- Data passed to the on_permission_request hook
--- @class agentic.UserConfig.PermissionRequestData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field tool_call_id string The tool call ID requesting permission

--- @class agentic.UserConfig.Hooks
--- @field on_prompt_submit? fun(data: agentic.UserConfig.PromptSubmitData): nil
--- @field on_response_complete? fun(data: agentic.UserConfig.ResponseCompleteData): nil
--- @field on_permission_request? fun(data: agentic.UserConfig.PermissionRequestData): nil

--- @class agentic.UserConfig.KeymapEntry
--- @field [1] string The key binding
--- @field mode string|string[] The mode(s) for this binding

--- @alias agentic.UserConfig.KeymapValue string | string[] | (string | agentic.UserConfig.KeymapEntry)[]

--- @class agentic.UserConfig.Keymaps
--- @field widget table<string, agentic.UserConfig.KeymapValue>
--- @field prompt table<string, agentic.UserConfig.KeymapValue>
--- @field chat table<string, agentic.UserConfig.KeymapValue>
--- @field diff_preview table<string, string>
--- @field permission string[] Keys for permission responses (position maps to option index)

--- Window options passed to nvim_set_option_value
--- Overrides default options (wrap, linebreak, winfixbuf, winfixheight)
--- @alias agentic.UserConfig.WinOpts table<string, any>

--- @class agentic.UserConfig
local ConfigDefault = {
    --- Enable printing debug messages which can be read via `:messages`
    debug = false,

    --- @type agentic.UserConfig.ProviderName
    provider = "claude-agent-acp",

    --- Auth type for Claude CLI re-authentication.
    --- Used when spawning `claude auth login` after an authentication error.
    --- @type "claudeai" | "console" | "sso"
    auth_type = "claudeai",

    --- Auto-continue after usage limit errors.
    --- When the provider reports "out of extra usage · resets Xpm", schedules
    --- a timer to send "continue" once the reset time arrives.
    auto_continue_on_usage_limit = true,

    --- @type table<agentic.UserConfig.ProviderName, agentic.acp.ACPProviderConfig|nil>
    acp_providers = {
        ["claude-agent-acp"] = {
            name = "Claude Agent ACP",
            command = "claude-agent-acp",
            env = {},
        },

        ["claude-acp"] = {
            name = "Claude ACP",
            command = "claude-code-acp",
            env = {},
        },

        ["gemini-acp"] = {
            name = "Gemini ACP",
            command = "gemini",
            args = { "--experimental-acp" },
            env = {},
        },

        ["codex-acp"] = {
            name = "Codex ACP",
            -- https://github.com/zed-industries/codex-acp/releases
            -- xattr -dr com.apple.quarantine ~/.local/bin/codex-acp
            command = "codex-acp",
            args = {
                -- "-c",
                -- "features.web_search_request=true", -- disabled as it doesn't send proper tool call messages
            },
            env = {},
        },

        ["opencode-acp"] = {
            name = "OpenCode ACP",
            command = "opencode",
            args = { "acp" },
            env = {},
        },

        ["cursor-acp"] = {
            name = "Cursor Agent ACP",
            command = "cursor-agent-acp",
            args = {},
            env = {},
        },

        ["auggie-acp"] = {
            name = "Auggie ACP",
            command = "auggie",
            args = {
                "--acp",
            },
            env = {},
        },

        ["mistral-vibe-acp"] = {
            name = "Mistral Vibe ACP",
            command = "vibe-acp",
            args = {},
            env = {},
        },
    },

    --- @class agentic.UserConfig.Windows.Chat
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Input
    --- @field height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Code
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Files
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Diagnostics
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Todos
    --- @field display boolean
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @alias agentic.UserConfig.Windows.Position "right"|"left"|"bottom"

    --- @class agentic.UserConfig.Windows
    --- @field position agentic.UserConfig.Windows.Position
    --- @field width string|number
    --- @field height string|number
    --- @field stack_width_ratio number
    --- @field max_wrap_width integer
    --- @field chat agentic.UserConfig.Windows.Chat
    --- @field input agentic.UserConfig.Windows.Input
    --- @field code agentic.UserConfig.Windows.Code
    --- @field files agentic.UserConfig.Windows.Files
    --- @field diagnostics agentic.UserConfig.Windows.Diagnostics
    --- @field todos agentic.UserConfig.Windows.Todos
    windows = {
        position = "right",
        width = "50%",
        height = "20%",
        stack_width_ratio = 0.4,
        max_wrap_width = 80,
        chat = { win_opts = {} },
        input = { height = 10, win_opts = {} },
        code = { max_height = 15, win_opts = {} },
        files = { max_height = 10, win_opts = {} },
        diagnostics = { max_height = 10, win_opts = {} },
        todos = { display = true, max_height = 10, win_opts = {} },
    },

    --- @type agentic.UserConfig.Keymaps
    keymaps = {
        --- Keys bindings for ALL buffers in the widget
        widget = {
            close = "<localLeader>q",
            stop_generation = {
                {
                    "<C-c>",
                    mode = { "n", "i" },
                },
            },
            change_mode = {
                {
                    "<S-Tab>",
                    mode = { "i", "n", "v" },
                },
            },
            continue = "<localLeader>c",
            restart_session = "<localLeader>!",
            restore_session = "<localLeader>R",
            refresh = "<localLeader>r",
            toggle_auto_scroll = "<localLeader>a",
            switch_provider = "<localLeader>s",
            switch_model = "<localLeader>m",
        },

        --- Keys bindings for the prompt buffer
        prompt = {
            submit = {
                "<CR>",
            },

            paste_image = {
                {
                    "<localLeader>p",
                    mode = { "n" },
                },
                {
                    "<C-v>", -- Same as Claude-code in insert mode
                    mode = { "i" },
                },
            },
        },

        --- Key bindings for the chat buffer
        chat = {
            prev_prompt = "[[",
            next_prompt = "]]",
        },

        --- Keys bindings for diff preview navigation
        diff_preview = {
            next_hunk = "]c",
            prev_hunk = "[c",
            open_in_tab = "<localLeader>d",
        },

        --- Keys for permission responses (Allow once, Allow always, etc.)
        --- Position maps to option index: permission[1] selects option 1, etc.
        --- Applied to all widget buffers while a permission prompt is active.
        permission = { "1", "2", "3", "4", "5" },
    },

    -- stylua: ignore start
    --- @class agentic.UserConfig.SpinnerChars
    --- @field generating string[]
    --- @field thinking string[]
    --- @field searching string[]
    --- @field busy string[]
    spinner_chars = {
        generating = { "·", "✢", "✳", "∗", "✻", "✽" },
        thinking = { "🤔", "🤨" },
        searching = { "🔎. . .", ". 🔎. .", ". . 🔎." },
        busy = { "⡀", "⠄", "⠂", "⠁", "⠈", "⠐", "⠠", "⢀", "⣀", "⢄", "⢂", "⢁", "⢈", "⢐", "⢠", "⣠", "⢤", "⢢", "⢡", "⢨", "⢰", "⣰", "⢴", "⢲", "⢱", "⢸", "⣸", "⢼", "⢺", "⢹", "⣹", "⢽", "⢻", "⣻", "⢿", "⣿", },
    },
    -- stylua: ignore end

    --- Icons used to identify tool call states
    --- @class agentic.UserConfig.StatusIcons
    status_icons = {
        pending = "󰔛",
        completed = "✔",
        failed = "",
    },

    --- Icons used for diagnostics in the context panel
    --- @class agentic.UserConfig.DiagnosticIcons
    --- @field error string
    --- @field warn string
    --- @field info string
    --- @field hint string
    diagnostic_icons = {
        error = "❌",
        warn = "⚠️",
        info = "ℹ️",
        hint = "✨",
    },

    --- @class agentic.UserConfig.PermissionIcons
    permission_icons = {
        plan_implement = "",
        allow_once = "",
        allow_always = "",
        reject_once = "",
        __reject_all__ = "",
        reject_always = "󰜺",
    },

    --- @class agentic.UserConfig.FilePicker
    --- @field enabled boolean Enable @-mention file completion
    --- @field max_files integer Max files for @-completion; shallow files preferred (0 = unlimited)
    file_picker = {
        enabled = true,
        max_files = 20000,
    },

    --- @class agentic.UserConfig.ImagePaste
    --- @field enabled boolean Enable image drag-and-drop to add images to referenced files
    image_paste = {
        enabled = true,
    },

    --- @class agentic.UserConfig.AutoScroll
    --- @field enabled boolean Whether auto-scroll is active (toggle at runtime with keymap)
    --- @field threshold integer Lines from bottom to trigger auto-scroll (default: 10)
    auto_scroll = {
        enabled = true,
        threshold = 10,
    },

    --- Show diff preview for edit tool calls in the buffer
    --- @class agentic.UserConfig.DiffPreview
    --- @field enabled boolean
    --- @field layout "inline" | "split"
    --- @field center_on_navigate_hunks boolean
    diff_preview = {
        enabled = true,
        layout = "split",
        center_on_navigate_hunks = true,
    },

    --- @type agentic.UserConfig.Hooks
    hooks = {
        on_prompt_submit = nil,
        on_response_complete = nil,
        on_permission_request = nil,
    },

    --- Set vim.wo.winbar on widget windows with the full header text
    --- (title + context). Disable if using an external plugin (e.g.
    --- incline.nvim) that renders its own per-window labels.
    winbar = true,

    --- Customize window headers for each panel in the chat widget.
    --- Each header can be either:
    --- 1. A table with title field
    --- 2. A function that receives header parts and returns a custom header string
    ---
    --- The context field is managed internally and shows dynamic info like counts.
    ---
    --- @type agentic.UserConfig.Headers
    headers = {
        input = function() end,
        files = function() end,
        chat = function() end,
        code = function() end,
        diagnostics = function() end,
        todos = function() end,
    },

    --- Maximum lines shown for tool call output before folding.
    --- Blocks exceeding the threshold are wrapped in fold markers and
    --- auto-closed (use zo/za/zc to toggle). Set to 0 to disable folding.
    --- @class agentic.UserConfig.ToolCallDisplay
    --- @field search_max_lines integer
    --- @field execute_max_lines integer
    --- @field execute_formatter? string|false Command to format execute code blocks (default: "shfmt"). Set to false to disable external formatting and use the built-in operator-splitting fallback only.
    tool_call_display = {
        search_max_lines = 8,
        execute_max_lines = 25,
        execute_formatter = "shfmt",
    },

    --- Notification settings
    --- @class agentic.UserConfig.Notifications
    --- @field bell boolean Ring vim bell on response complete and permission request
    notifications = {
        bell = false,
    },

    --- Auto-approve Bash permission requests when every segment of a compound
    --- command (split on |, &&, ||, ;) individually matches an allow pattern
    --- from ~/.claude/settings.json. Supplements the provider's built-in check.
    auto_approve_compound_commands = true,

    --- Auto-approve read-only tool calls (Read, Grep, Glob — ACP kinds "read"
    --- and "search") without prompting, regardless of target path. These tools
    --- cannot mutate the filesystem.
    auto_approve_read_only_tools = true,

    --- Control various behaviors and features of the plugin
    --- @class agentic.UserConfig.Settings
    settings = {

        --- Automatically move cursor to chat window after submitting a prompt
        move_cursor_to_chat_on_submit = true,
    },

    --- @class agentic.UserConfig.SessionRestore
    --- @field storage_path? string Path to store session data; if nil, default path is used: ~/.cache/nvim/agentic/sessions/
    --- @field picker? "quickfix"|"fzf-lua"|"select" Session picker backend.
    --- "quickfix" (default) — quickfix window with delete/undo/scope toggle keymaps.
    --- "fzf-lua" — fzf-lua with preview and scope toggle; falls back to quickfix if not installed.
    --- "select" — delegates to vim.ui.select (works with dressing.nvim, etc; no scope toggle or delete).
    session_restore = {
        storage_path = nil,
        picker = "quickfix",
    },
}

return ConfigDefault
