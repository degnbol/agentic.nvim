--- List of supported ACP providers
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

    --- `"tab"` opens the widget in a dedicated tabpage (no file window),
    --- closes the tab on hide. `"right"`, `"left"`, `"bottom"` split in the
    --- current tab next to the existing windows.
    --- @alias agentic.UserConfig.Windows.Position "right"|"left"|"bottom"|"tab"

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
            --- Whole-buffer submit binding. Default empty because partial-send
            --- owns normal-mode <CR>. `:w` / `:Wq` / `:X` always submit the
            --- whole buffer regardless of this binding.
            submit = {},

            --- Send N lines (vim.v.count1) from cursor, then delete them.
            send_line = "<CR><CR>",

            --- Operator (g@). `<CR>{motion}` sends text covered by motion,
            --- linewise for linewise motions, charwise for charwise.
            send_operator = "<CR>",

            --- Visual-mode binding. Sends the selection, then deletes it.
            send_visual = "<CR>",

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
            --- Open the file under the cursor in a new tab and place the
            --- cursor at the corresponding line/column of the diff. Falls
            --- back to the hunk start when cursor is on a deleted line or
            --- on the block header. The chat buffer's `winfixbuf` makes
            --- the default `gf` error, so this override is the natural
            --- mapping for that key.
            open_diff_file = "gf",
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
    --- @field pause_on_prose boolean Pin the start of a prose run to the top of the viewport so the model's narrative stays readable; auto-scroll resumes when the next tool call begins
    auto_scroll = {
        enabled = true,
        threshold = 10,
        pause_on_prose = true,
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
    --- @field diff_context_max_lines integer Skip context-aware diff highlighting when the target file exceeds this many lines (each Edit render reparses the whole file). Set to 0 to disable the feature entirely.
    tool_call_display = {
        search_max_lines = 8,
        execute_max_lines = 25,
        execute_formatter = "shfmt",
        diff_context_max_lines = 5000,
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

    --- Auto-approve common read-only Bash commands (ls, cat, head, tail, stat,
    --- find without -exec/-delete/-ok, etc.) without prompting. Patterns are
    --- merged into the same allow/deny pools as ~/.claude/settings.json, so
    --- providers without a Claude settings.json still benefit. The compound
    --- command splitter still requires every segment to match.
    auto_approve_read_only_commands = true,

    --- @type string[] Allow patterns evaluated when
    --- `auto_approve_read_only_commands` is true. Same `Bash(...)` glob format
    --- as Claude's settings.json. Replace the whole list to customise.
    read_only_commands = {
        "Bash(ls)",
        "Bash(ls *)",
        "Bash(cat *)",
        "Bash(head *)",
        "Bash(tail *)",
        "Bash(less *)",
        "Bash(zless *)",
        "Bash(wc)",
        "Bash(wc *)",
        "Bash(tree)",
        "Bash(tree *)",
        "Bash(du)",
        "Bash(du *)",
        "Bash(df)",
        "Bash(df *)",
        "Bash(file *)",
        "Bash(stat *)",
        "Bash(which *)",
        "Bash(whereis *)",
        "Bash(type *)",
        "Bash(realpath *)",
        "Bash(readlink *)",
        "Bash(dirname *)",
        "Bash(basename *)",
        "Bash(pwd)",
        "Bash(pwd *)",
        "Bash(echo *)",
        "Bash(printf *)",
        "Bash(seq *)",
        "Bash(grep *)",
        "Bash(rg *)",
        "Bash(ag *)",
        "Bash(ack *)",
        "Bash(pdfgrep *)",
        "Bash(pdftotext *)",
        "Bash(find *)",
        "Bash(diff *)",
        "Bash(cmp *)",
        "Bash(comm *)",
        "Bash(git diff)",
        "Bash(git diff *)",
        "Bash(git log)",
        "Bash(git log *)",
        "Bash(git show)",
        "Bash(git show *)",
        "Bash(git status)",
        "Bash(git status *)",
        "Bash(git blame *)",
        "Bash(git rev-parse *)",
        "Bash(git branch)",
        "Bash(git branch --list*)",
        "Bash(git remote)",
        "Bash(git remote -v)",
        "Bash(git tag)",
        "Bash(git tag --list*)",
        "Bash(git ls-files*)",
        "Bash(git ls-tree*)",
        "Bash(git cat-file *)",
        "Bash(sort *)",
        "Bash(uniq *)",
        "Bash(cut *)",
        "Bash(tr *)",
        "Bash(column *)",
        "Bash(jq *)",
        "Bash(yq *)",
        "Bash(xq *)",
        "Bash(xmllint *)",
        "Bash(xxd *)",
        "Bash(hexdump *)",
        "Bash(od *)",
        "Bash(strings *)",
        "Bash(md5 *)",
        "Bash(md5sum *)",
        "Bash(gzcat *)",
        "Bash(bzcat *)",
        "Bash(xzcat *)",
        "Bash(lz4cat *)",
        "Bash(zstdcat *)",
        "Bash(man)",
        "Bash(man *)",
        "Bash(info)",
        "Bash(info *)",
        "Bash(apropos *)",
        "Bash(whatis *)",
        "Bash(tldr *)",
        "Bash(help)",
        "Bash(help *)",
        "Bash(uname)",
        "Bash(uname *)",
        "Bash(hostname)",
        "Bash(date)",
        "Bash(date *)",
        "Bash(cal)",
        "Bash(cal *)",
        "Bash(uptime)",
        "Bash(id)",
        "Bash(id *)",
        "Bash(whoami)",
        "Bash(groups)",
        "Bash(groups *)",
        "Bash(who)",
        "Bash(who *)",
        "Bash(w)",
        "Bash(w *)",
        "Bash(ps)",
        "Bash(ps *)",
        "Bash(pgrep *)",
        "Bash(pidof *)",
        "Bash(pstree)",
        "Bash(pstree *)",
        "Bash(lsof *)",
        "Bash(dig *)",
        "Bash(host *)",
        "Bash(nslookup *)",
        "Bash(ping *)",
        "Bash(traceroute *)",
        "Bash(ss)",
        "Bash(ss *)",
        "Bash(netstat)",
        "Bash(netstat *)",
        "Bash(env)",
        "Bash(printenv)",
        "Bash(printenv *)",
        "Bash(bat *)",
        "Bash(eza)",
        "Bash(eza *)",
        "Bash(lsd)",
        "Bash(lsd *)",
        "Bash(fd *)",
        "Bash(mdfind *)",
        "Bash(locate *)",
        "Bash(defaults read)",
        "Bash(defaults read *)",
        "Bash(xattr)",
        "Bash(xattr -l *)",
        "Bash(xattr -h)",
        "Bash(sed *)",
    },

    --- @type string[] Deny patterns that override `read_only_commands` allow
    --- entries (precedence matches Claude's settings.json behaviour). Used to
    --- carve unsafe variants out of broad allows like `Bash(find *)` and to
    --- block in-place modification flags (e.g. `sed -i`).
    read_only_commands_deny = {
        "Bash(find * -exec *)",
        "Bash(find * -delete*)",
        "Bash(find * -ok *)",
        "Bash(fd * -x *)",
        "Bash(fd * -X *)",
        "Bash(fd * --exec *)",
        "Bash(fd * --exec-batch *)",
        "Bash(sed -i*)",
        "Bash(sed * -i*)",
        "Bash(date -s*)",
        "Bash(date --set*)",
    },

    --- Enable the /trust slash command and its client-side auto-approval
    --- layer for file-scoped tool kinds (edit, write, create, delete, move).
    --- When false, /trust is rejected and the trust check in
    --- PermissionManager:_try_auto_approve is skipped entirely. Trust scope is
    --- always per-session (cleared on /new and tabpage close); this option
    --- only gates the feature.
    auto_approve_trust_scope = true,

    --- Control various behaviors and features of the plugin
    --- @class agentic.UserConfig.Settings
    --- @field move_cursor_to_chat_on_submit boolean
    --- @field send_register? string
    --- @field write_submit boolean
    settings = {

        --- Automatically move cursor to chat window after submitting a prompt
        move_cursor_to_chat_on_submit = true,

        --- Register name to copy sent text into before deleting on
        --- partial-send. Nil writes no register.
        send_register = nil,

        --- When true, `:w` in the input buffer submits the prompt. `:wq` and
        --- `:x` submit and emit a warning instead of closing; `:wq!` and `:x!`
        --- submit and close. When false, none of these are registered and the
        --- input buffer remains a plain `nofile` buffer.
        write_submit = true,
    },

    --- @class agentic.UserConfig.SessionRestore
    --- @field storage_path? string Path to store session data; if nil, default path is used: ~/.cache/nvim/agentic/sessions/
    --- @field picker? "quickfix"|"fzf-lua"|"select" Session picker backend.
    --- "quickfix" (default) — quickfix window with delete/undo/scope toggle keymaps.
    --- "fzf-lua" — fzf-lua with preview and scope toggle; falls back to quickfix if not installed.
    --- "select" — delegates to vim.ui.select (works with dressing.nvim, etc; no scope toggle or delete).
    --- @field confirm_delete? boolean Prompt for confirmation before /delete (default: true)
    session_restore = {
        storage_path = nil,
        picker = "quickfix",
        confirm_delete = true,
    },
}

return ConfigDefault
