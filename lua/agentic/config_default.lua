--- List of supported ACP providers
--- @alias agentic.UserConfig.ProviderName
--- | "claude-agent-acp"
--- | "gemini-acp"
--- | "codex-acp"
--- | "opencode-acp"
--- | "cursor-acp"
--- | "auggie-acp"
--- | "mistral-vibe-acp"

--- @alias agentic.UserConfig.HeaderRenderFn fun(parts: agentic.ui.ChatWidget.HeaderParts): string|nil

--- @alias agentic.UserConfig.HeaderTable { icon?: string, title?: string }

--- User config headers - each panel can have either config parts or a custom render function
--- @alias agentic.UserConfig.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.UserConfig.HeaderTable|agentic.UserConfig.HeaderRenderFn|nil>

--- Data passed to the on_prompt_submit hook
--- @class agentic.UserConfig.PromptSubmitData
--- @field prompt string The user's prompt text
--- @field session_id string The ACP session ID

--- Data passed to the on_response_complete hook
--- @class agentic.UserConfig.ResponseCompleteData
--- @field session_id string The ACP session ID
--- @field success boolean Whether response completed without error
--- @field error? table Error details if failed

--- Data passed to the on_permission_request hook
--- @class agentic.UserConfig.PermissionRequestData
--- @field session_id string The ACP session ID
--- @field tool_call_id string The tool call ID requesting permission

--- @class agentic.UserConfig.Hooks
--- @field on_prompt_submit? fun(data: agentic.UserConfig.PromptSubmitData): nil
--- @field on_response_complete? fun(data: agentic.UserConfig.ResponseCompleteData): nil
--- @field on_permission_request? fun(data: agentic.UserConfig.PermissionRequestData): nil

--- @class agentic.UserConfig.KeymapEntry
--- @field [1] string The key binding
--- @field mode string|string[] The mode(s) for this binding

--- @alias agentic.UserConfig.KeymapValue string | string[] | (string | agentic.UserConfig.KeymapEntry)[]

--- @alias agentic.UserConfig.PromptSpec string | { prompt: string, mode?: string|string[], desc?: string }

--- @class agentic.UserConfig.Keymaps
--- @field widget table<string, agentic.UserConfig.KeymapValue>
--- @field prompts table<string, agentic.UserConfig.PromptSpec>
--- @field prompt table<string, agentic.UserConfig.KeymapValue>
--- @field agent agentic.UserConfig.Keymaps.Agent
--- @field permission table<string, string> Key for permission responses by option kind
--- @field permission_open agentic.UserConfig.Keymaps.PermissionOpen

--- @class agentic.UserConfig.Keymaps.Agent
--- @field to_input string|string[]
--- @field [string] agentic.UserConfig.KeymapValue

--- @class agentic.UserConfig.Keymaps.PermissionOpen
--- @field edit string|false In the current window (`:edit`)
--- @field split string|false In a split
--- @field vsplit string|false In a vertical split
--- @field tab string|false In a new last tabpage

--- Window options passed to nvim_set_option_value
--- Overrides the window options the widget sets
--- @alias agentic.UserConfig.WinOpts table<string, any>

--- @class agentic.UserConfig
local ConfigDefault = {
    --- Enable printing debug messages which can be read via `:messages`
    debug = false,

    --- Enable appending debug messages to a log file at
    --- `vim.fn.stdpath("log") .. "/agentic/agentic.log"` (typically
    --- `~/.local/state/nvim/agentic/agentic.log`). At 10 MB the file moves to
    --- `agentic.log.1`, replacing the previous one. Independent of
    --- `debug` — set this without `debug` to log without screen distraction.
    log = false,

    --- @type agentic.UserConfig.ProviderName
    provider = "claude-agent-acp",

    --- Auto-retry after transient server errors.
    --- When a turn dies mid-stream (connection closed, API unreachable,
    --- overloaded), resend "continue" immediately, up to 3 times. Nothing is
    --- shown in the chat until the budget runs out.
    auto_retry_on_transient_error = true,

    --- @type table<agentic.UserConfig.ProviderName, agentic.acp.ACPProviderConfig|nil>
    acp_providers = {
        ["claude-agent-acp"] = {
            name = "Claude Agent ACP",
            command = "claude-agent-acp",
            env = {},
            auth_method = "claude-ai-login",

            --- Offer the Claude Code todo/task tools (TaskCreate, TaskUpdate,
            --- TaskList, TaskGet, TodoWrite) to the agent.
            --- Turns the plan pane on and off: the bridge renders Task* calls
            --- as ACP `plan` updates rather than tool calls, and nothing else
            --- writes there.
            todo_tools = true,

            --- Claude Code `--allowedTools` permission rules. Naming Grep or Glob
            --- gives the agent both tools. A matching tool call bypasses the
            --- permission prompt, `auto_approve_kinds` and `/grant`; the
            --- default scope matches no path, so it approves nothing.
            allowed_tools = { "Grep(//dev/null/**)", "Glob(//dev/null/**)" },

            --- @class agentic.UserConfig.Subagents
            --- @field force_background boolean Run every Agent (Task) spawn in the background, whatever the model passes for `run_in_background`.
            subagents = {
                force_background = false,
            },

            --- Auto-continue after usage limit errors.
            --- When the provider reports "out of extra usage · resets Xpm",
            --- schedules a timer to send "continue" once the reset time
            --- arrives.
            auto_continue_on_usage_limit = true,
        } --[[@as agentic.acp.ClaudeProviderConfig]],

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

    --- @class agentic.UserConfig.Windows.Agent
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

    --- @class agentic.UserConfig.Windows.Activity
    --- @field display boolean Track the files the agent changes and offer the toggle panel
    --- @field max_height number
    --- @field hide_reverted boolean Drop rows whose change is no longer on disk — undone, or committed
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Info
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Todos
    --- @field display boolean
    --- @field max_height number
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows.Subagent
    --- @field win_opts? agentic.UserConfig.WinOpts

    --- @class agentic.UserConfig.Windows
    --- @field stack agentic.ui.ChatWidget.StackPanel[] Top-to-bottom order of the panels below the chat, each listed once
    --- @field wrap_width integer Hard-wrap width of chat prose, or 0 to soft-wrap instead
    --- @field agent agentic.UserConfig.Windows.Agent
    --- @field input agentic.UserConfig.Windows.Input
    --- @field code agentic.UserConfig.Windows.Code
    --- @field files agentic.UserConfig.Windows.Files
    --- @field diagnostics agentic.UserConfig.Windows.Diagnostics
    --- @field activity agentic.UserConfig.Windows.Activity
    --- @field info agentic.UserConfig.Windows.Info
    --- @field todos agentic.UserConfig.Windows.Todos
    --- @field subagent agentic.UserConfig.Windows.Subagent
    windows = {
        stack = {
            "todos",
            "code",
            "files",
            "diagnostics",
            "activity",
            "info",
            "input",
        },
        wrap_width = 80,
        agent = { win_opts = {} },
        input = { height = 10, win_opts = {} },
        code = { max_height = 15, win_opts = {} },
        files = { max_height = 10, win_opts = {} },
        diagnostics = { max_height = 10, win_opts = {} },
        activity = {
            display = true,
            max_height = 10,
            hide_reverted = true,
            win_opts = {},
        },
        info = { max_height = 10, win_opts = {} },
        todos = { display = true, max_height = 10, win_opts = {} },
        subagent = { win_opts = {} },
    },

    --- @type agentic.UserConfig.Keymaps
    keymaps = {
        --- Keys bindings for ALL buffers in the widget
        widget = {
            stop_generation = {
                {
                    "<C-c>",
                    mode = { "n", "i" },
                },
            },
            change_mode = {
                {
                    "<localLeader>m",
                    mode = { "n", "v" },
                },
            },
            toggle_activity = "<localLeader>f",
            toggle_info = "<localLeader>I",
            restart_session = "<localLeader>!",
            resume_session = "<localLeader>R",
            refresh = "",
            toggle_follow = "<localLeader>a",
            goto_bottom = "<localLeader>G",
            switch_provider = "<localLeader>p",
            switch_model = "<localLeader>M",
            switch_thought_level = "<localLeader>E",
        },

        --- Put a fixed prompt at the end of this widget's input buffer, with
        --- the cursor on it in normal mode. key → prompt text
        --- (or { prompt, mode?, desc? } for mode/desc control). Applied to
        --- every widget buffer, so these only exist while a session is open.
        --- Merges by key, so user entries add to these defaults. Set a key to
        --- vim.NIL or "" to disable an inherited entry — plain `nil` does NOT
        --- disable (a nil value is absent from the table, so the merge keeps
        --- the default).
        prompts = {
            ["<localLeader>c"] = "Continue",
        },

        --- Keys bindings for the prompt buffer
        prompt = {
            --- Whole-buffer submit binding. Default empty because partial-send
            --- owns normal-mode <CR>. `:w` always submits the whole buffer
            --- regardless of this binding.
            submit = {},

            --- Send N lines (vim.v.count1) from cursor, then delete them.
            send_line = "<CR><CR>",

            --- Operator (g@). `<CR>{motion}` sends text covered by motion,
            --- linewise for linewise motions, charwise for charwise.
            send_operator = "<CR>",

            --- Visual-mode binding. Sends the selection, then deletes it.
            send_visual = "<CR>",

            --- Queue keymaps mirror the send keymaps but always defer: instead
            --- of sending now, they tag the covered line(s) as a queued region
            --- (highlighted in place, still editable) that dispatches at the
            --- next turn to end normally.
            --- Queueing is line-granular — a charwise motion queues its full
            --- line(s). `<S-CR>` / `<S-C-c>` are only distinguishable from
            --- `<CR>` / `<C-c>` under the kitty keyboard protocol (kitty +
            --- nvim 0.12); on other terminals these bindings won't fire.

            --- Queue N lines (vim.v.count1) from the cursor.
            queue_line = "<S-CR><S-CR>",

            --- Operator (g@). `<S-CR>{motion}` queues the line(s) the motion
            --- covers.
            queue_operator = "<S-CR>",

            --- Visual-mode binding. Queues the selected line(s).
            queue_visual = "<S-CR>",

            --- Drop every queued region in the input buffer, leaving the text
            --- as ordinary draft in place.
            cancel_queue = "<S-C-c>",

            --- Opt-in. Needs img-clip.nvim.
            --- Example: `{ { "<C-v>", mode = { "i" } } }`
            paste_image = "",
        },

        --- Keys for the chat and subagent transcripts
        agent = {
            prev_prompt = "[[",
            next_prompt = "]]",

            --- Chat only. Fork the conversation before the turn at the cursor
            --- into a new chat, with that turn's prompt as its draft.
            --- `<C-w>` before the key opens it in a split, `<C-w>g` in a tab.
            fork = "<localLeader>F",

            --- Normal-mode keys that move to this buffer's input, then run
            --- there as typed, at the input's own cursor. Also bound in the
            --- panels.
            to_input = { "a", "A", "i", "I", "o", "O", "gi", "gI", "p", "P" },
        },

        --- Keys for permission responses by option kind. An option with no key
        --- here, or whose kind's key an earlier option took, gets
        --- `<localLeader>` and its position in the prompt.
        --- Applied to all widget buffers while a permission prompt is active.
        permission = {
            allow_once = "<localLeader>y",
            allow_always = "<localLeader>Y",
            reject_once = "<localLeader>n",
            reject_always = "<localLeader>N",
            __reject_all__ = "<localLeader>x",
            plan_implement = "<localLeader>i",
        },

        --- Each key opens the prompting subagent's transcript, only while its
        --- prompt is shown on the chat. `false` disables a key.
        permission_open = {
            edit = "<localLeader>e",
            split = "<localLeader>s",
            vsplit = "<localLeader>v",
            tab = "<localLeader>t",
        },
    },

    --- Icons used to identify tool call states
    --- @class agentic.UserConfig.StatusIcons
    status_icons = {
        pending = "󰔛",
        in_progress = "󰁪",
        completed = "✔",
        failed = "",
        rejected = "󰜺",
        interrupted = "󰓛",
        -- Same glyph as the header's running state: both mean "still running".
        background = "󰔟",
        stopped = "󰓛",
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

    --- @class agentic.UserConfig.Follow
    --- @field enabled boolean Whether the chat view follows new output (toggle at runtime with keymap)
    --- @field pause_on_prose boolean Pin the start of a prose run to the top of the viewport so the model's narrative stays readable. The pin releases at the next non-prose write to chat; a run taller than the window then leaves the window in user control
    --- @field bottom_padding integer Rows to reserve below the last buffer line so the thinking/generating indicator stays visible when it appears
    follow = {
        enabled = true,
        pause_on_prose = true,
        bottom_padding = 1,
    },

    --- Floating window that renders permission prompts. Anchored to a corner
    --- of the chat window so it stays in view regardless of where the
    --- streaming content currently is.
    --- @class agentic.UserConfig.PermissionFloat
    --- @field anchor "NE"|"NW"|"SE"|"SW" Chat-window corner to anchor to
    --- @field width integer Content width in columns (border drawn around)
    --- @field row_offset integer Inset from the anchored corner (positive = down for N*, up for S*)
    --- @field col_offset integer Inset from the anchored corner (positive = right for *W, left for *E)
    --- @field border string|string[] nvim_open_win border style
    --- @field winblend integer 0..100 transparency
    permission_float = {
        anchor = "SE",
        width = 30,
        row_offset = 1,
        col_offset = -1,
        border = "rounded",
        winblend = 0,
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
    --- 1. A table with icon and/or title fields
    --- 2. A function that receives header parts and returns a custom header string
    ---
    --- The context field is managed internally and shows dynamic info like counts.
    ---
    --- @type agentic.UserConfig.Headers
    headers = {
        input = function() end,
        files = function() end,
        agent = function() end,
        code = function() end,
        diagnostics = function() end,
        todos = function() end,
    },

    --- Maximum lines shown for tool call output before its fold closes (use
    --- zo/za/zc to toggle). An execute or search block has a second fold over
    --- its command and output, closed when the call is read-only and did not
    --- fail. A failed call's reason (any kind but execute) folds closed past
    --- one row, whatever the threshold.
    --- @class agentic.UserConfig.ToolCallDisplay
    --- @field search_max_lines integer Close a search block's output fold past this many lines; 0 never closes it by length. The fold over command and output closes whenever the search did not fail.
    --- @field execute_max_lines integer Close an execute block's output fold past this many lines; 0 never closes it by length. The fold over command and output closes when the command is read-only (`:h agentic-permissions-shell`) and did not fail.
    --- @field other_max_lines integer Fold generic/MCP/meta tool-result bodies (non-execute) exceeding this many lines. Set to 0 to disable folding for these.
    --- @field execute_formatter? string|false Command to format execute code blocks (default: "shfmt"). Set to false to disable external formatting and use the built-in operator-splitting fallback only.
    --- @field diff_context_max_lines integer Skip context-aware diff highlighting when the target file exceeds this many lines (each Edit render reparses the whole file). Set to 0 to disable the feature entirely.
    --- @field create_max_lines integer Fold a created-file diff closed when it exceeds this many lines (0 = always open). An edit diff stays open unless the edit failed.
    --- @field background_tail_lines integer Last lines of a background command's output file shown under its block
    tool_call_display = {
        search_max_lines = 8,
        execute_max_lines = 25,
        other_max_lines = 25,
        execute_formatter = "shfmt",
        diff_context_max_lines = 10000,
        create_max_lines = 50,
        background_tail_lines = 10,
    },

    --- Notification settings
    --- @class agentic.UserConfig.Notifications
    --- @field bell boolean Ring vim bell on response complete and permission request
    notifications = {
        bell = true,
    },

    --- @class agentic.UserConfig.Permissions
    --- @field use_plugin_defaults boolean Load the bundled structured rules from permissions.json
    --- @field use_claude_settings boolean Match the Bash(...) allow/deny/ask patterns in the global and project Claude settings.json
    --- @field auto_approve_kinds string[] ACP tool kinds approved without a prompt, whatever the target path
    --- @field auto_approve_tier agentic.PermAutoApproveTier Which allow rules auto-approve execute calls. Settings.json allow patterns count under either tier. nil approves none (deny/ask still apply).
    --- @field structured agentic.StructuredEntries Cmd-keyed structured rules merged over the bundled permissions.json (deep-extend "force"). A user kind-array replaces the bundled array of that kind; kinds the user omits stay bundled. Set a cmd to vim.NIL to disable the bundled entry.
    --- @field highlight_unapproved boolean Highlight the non-known-safe parts of an execute permission prompt while it is shown (independent of `auto_approve_tier`).
    --- @field tmp_cleanup boolean In a granted path under a tmp root, auto-approve a plain `rm` of an untracked tmp file redirected to earlier in the same Bash command.
    --- @field default_grant string[] Paths or globs granted at session start, as with `/grant`. `$VAR` and `~` expand (an entry naming an unset var is skipped), and a relative entry resolves against the session cwd. `{}` starts a session without grants.
    permissions = {
        use_plugin_defaults = true,
        use_claude_settings = true,
        auto_approve_kinds = { "read", "search", "skill" },
        auto_approve_tier = "safe_write",
        structured = {},
        highlight_unapproved = true,
        tmp_cleanup = true,
        default_grant = { "/tmp", "$TMPDIR", ".", "root" },
    },

    --- Control various behaviors and features of the plugin
    --- @class agentic.UserConfig.Settings
    --- @field move_cursor_to_agent_on_submit boolean
    --- @field send_register? string
    --- @field write_submit boolean
    settings = {

        --- When true, focus moves to the chat window after submitting a
        --- prompt. When false, the input window keeps focus.
        move_cursor_to_agent_on_submit = false,

        --- Register name to copy sent text into before deleting on
        --- partial-send. Nil writes no register.
        send_register = nil,

        --- When true, `:w` in the input buffer submits the prompt, so `:wq`
        --- and `:x` submit and close the input window. When false, the input
        --- buffer is a plain `nofile` buffer.
        write_submit = true,
    },

    --- @class agentic.UserConfig.Sessions
    --- @field storage_path? string Path to store session data; if nil, default path is used: ~/.cache/nvim/agentic/sessions/
    --- @field picker? "quickfix"|"fzf-lua"|"select" Session picker backend.
    --- "quickfix" (default) — quickfix window with delete/undo/scope toggle keymaps.
    --- "fzf-lua" — fzf-lua with preview and scope toggle; falls back to quickfix if not installed.
    --- "select" — delegates to vim.ui.select (works with dressing.nvim, etc; no scope toggle or delete).
    --- @field confirm_delete? boolean Prompt for confirmation before /delete (default: true)
    --- @field cd_on_load? boolean Change nvim's working directory to the session's recorded cwd on resume (default: true). Applies to every resume: the picker, `:AgenticResume` and `load_acp_session`.
    sessions = {
        storage_path = nil,
        picker = "quickfix",
        confirm_delete = true,
        cd_on_load = true,
    },

    --- Model calls without an agent session: text in, text out.
    --- @class agentic.UserConfig.TextModel
    --- @field url? string Base URL of an OpenAI-compatible API, e.g. "http://localhost:4000/v1"; nil disables text-model features
    --- @field api_key_env? string Name of the env var holding the API key; nil sends no Authorization header
    --- @field timeout_ms integer Per-request timeout
    text_model = {
        url = nil,
        api_key_env = nil,
        timeout_ms = 60000,
    },

    --- Agent sessions the plugin drives on behalf of a chat.
    --- @class agentic.UserConfig.Background
    --- @field list_buffers boolean Whether their transcript buffers are listed
    background = {
        list_buffers = true,
    },

    --- @class agentic.UserConfig.SkepticModel
    --- @field provider string Only "opencode-acp"
    --- @field model string Model value id, e.g. "litellm/glm-5.3"

    --- Background checks of the main agent's claims after each turn. Needs
    --- `text_model.url`. `:h agentic-skeptic`
    --- @class agentic.UserConfig.Skeptic
    --- @field enabled boolean On in every new session; `/skeptic on|off` sets one session
    --- @field reporting_criteria "agree"|"either" Forward a claim when every skeptic refutes it, or when any skeptic refutes it with evidence
    --- @field extractor { model: string } The `text_model` model that extracts claims
    --- @field skeptics agentic.UserConfig.SkepticModel[]
    --- @field turn_timeout_ms integer Per skeptic turn, and for a skeptic session to become ready
    --- @field max_refusals integer Refusal prompts per check before a skeptic gives up
    --- @field prompts table<string, string> Overrides of the prompt texts, keyed `extract`, `verify`, `deliver` or `refusal`
    skeptic = {
        enabled = false,
        reporting_criteria = "agree",
        extractor = { model = "deepseek-v4.1-flash" },
        skeptics = {
            { provider = "opencode-acp", model = "litellm/glm-5.3" },
            { provider = "opencode-acp", model = "litellm/kimi-k3" },
        },
        turn_timeout_ms = 300000,
        max_refusals = 3,
        prompts = {},
    },
}

return ConfigDefault
