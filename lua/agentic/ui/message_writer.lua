local AcpKind = require("agentic.utils.acp_kind")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local ExtmarkBlock = require("agentic.utils.extmark_block")
local Glyphs = require("agentic.glyphs")
local Logger = require("agentic.utils.logger")
local PromptBlocks = require("agentic.utils.prompt_blocks")
local Renderer = require("agentic.ui.tool_call_renderer")
local TextWrap = require("agentic.utils.text_wrap")
local Theme = require("agentic.theme")

local NS_ERROR = vim.api.nvim_create_namespace("agentic_error")
--- Anchors a `*-fold` fence's opening line so a deferred close (chat window
--- hidden at write time) lands on the right row after later edits shift it.
local NS_FOLD_ANCHORS = vim.api.nvim_create_namespace("agentic_fold_anchors")
--- Per-turn token-usage footer (right-aligned virt_text on the turn-boundary
--- blank line). Own namespace so it stays out of the fold/tool clear paths;
--- footers are stamped once and never updated or cleared.
local NS_TURN_USAGE = vim.api.nvim_create_namespace("agentic_turn_usage")

--- Synchronously materialise treesitter injections for a buffer row range.
--- The chat buffer's highlighter parses injections asynchronously under the
--- 'redrawtime' budget (see `:h vim.treesitter` / languagetree `_async_parse`),
--- yielding at 3ms steps. A heavy redraw can yield before reaching a block's
--- injected fence — e.g. an execute command's ```zsh — leaving it with only
--- the parent markup highlight until some unrelated later reparse. A
--- callback-less `parse(range)` runs to completion with no time budget, so the
--- injection child trees are created deterministically.
---
--- Called after every content `set_lines`, not just on a finalised block, so a
--- block that is rewritten mid-stream is re-highlighted with each version of
--- its content. After a `set_lines` the range is dirty, so this is a real
--- range-parse (one per block update); `parse` short-circuits only when the
--- range is already valid. Folds do not depend on this — `agentic.ui.folds`
--- reads the root tree only.
--- @param bufnr integer
--- @param start_row integer 0-indexed first row of the block
--- @param end_row integer 0-indexed last row of the block
local function materialize_injections(bufnr, start_row, end_row)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if ok and parser then
        parser:parse({ start_row, end_row })
    end
end

--- Tool call statuses that will not change again (safe to force a final parse).
--- @param status string|nil
--- @return boolean
local function is_final_status(status)
    return status == "completed" or status == "failed" or status == "cancelled"
end

--- @class agentic.ui.MessageWriter.HighlightRange
--- @field type "comment"|"error"|"old"|"new"|"new_modification" Type of highlight to apply
--- @field line_index integer Line index relative to returned lines (0-based)
--- @field old_line? string Original line content (for diff types)
--- @field new_line? string Modified line content (for diff types)
--- @field block_col_hl? table<integer, string> Byte-col → language-qualified capture name from context-aware treesitter parse

--- @class agentic.ui.MessageWriter.SearchMatch
--- @field line_index integer Line index relative to block lines (0-based)
--- @field col_start integer Start column (byte offset)
--- @field col_end integer End column (byte offset)
--- @field hl_group? string Highlight group override (default: AgenticSearchMatch)

--- @class agentic.ui.MessageWriter.ToolCallDiff
--- @field new string[]
--- @field old string[]
--- @field all? boolean

--- An inclusive 1-based line range in a file's post-edit content.
--- @class agentic.ui.MessageWriter.HunkRange
--- @field start_line integer
--- @field end_line integer

--- A tool call status as this plugin renders it: the wire enum plus the
--- client-stamped `cancelled`, which a turn's cancellation puts on the calls
--- the provider abandoned without a final update of its own.
--- @alias agentic.ui.ToolCallStatus agentic.acp.ToolCallStatus|"cancelled"

--- How an Agent-tool subagent runs: `blocking` holds the parent's tool call
--- open until the agent ends, `background` returns it at launch.
--- @alias agentic.ui.MessageWriter.SubagentMode "background"|"blocking"

--- Identity and execution mode of a subagent.
--- @class agentic.ui.MessageWriter.SubagentInfo
--- @field label? string Display name of the agent. Always set at spawn, absent only on blocks saved by earlier versions
--- @field agent_type? string Subagent type, once the SDK's record of the spawn is read
--- @field mode agentic.ui.MessageWriter.SubagentMode
--- @field confirmed boolean `mode` comes from the SDK's record of the spawn rather than a prediction
--- @field agent_id? string Id addressing the agent, for its tools such as SendMessage and TaskStop

--- @class agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id string
--- @field status agentic.ui.ToolCallStatus
--- @field body? string[]
--- @field diff? agentic.ui.MessageWriter.ToolCallDiff
--- @field kind? agentic.acp.ToolKind
--- @field argument? string
--- @field search_pattern? string Regex pattern for highlighting matches in search output
--- @field read_range? { offset: integer, limit?: integer } Line range for partial reads
--- @field failure_reason? string[] Error message shown in place of kind-specific body when status == "failed" (e.g. hook-denial reason, tool error). Extracted from rawOutput, so no ``` fences.
--- @field description? string Model-provided one-line summary of the call (e.g. a Bash command's `description`), rendered as a title line under the header. Distinct from body (the output) and argument (the command).
--- @field file_created? boolean Whether the call created the file rather than changing existing content. Reported after the tool runs, so absent until then — a mutation with no value here has not been told either way, which is not the same as false.
--- @field hunk_ranges? agentic.ui.MessageWriter.HunkRange[] Post-edit line range of each changed hunk, as reported by the provider. Not rendered; recorded so the range survives a session restore, which re-deriving from disk cannot (the file is post-edit by then).
--- @field skill_path? string Absolute path to the SKILL.md a Skill call loaded, verified to exist when it was resolved. Absent when no root held the skill.
--- @field subagent? agentic.ui.MessageWriter.SubagentInfo Set on a subagent's block in the main chat

--- @class agentic.ui.MessageWriter.ToolCallBlock : agentic.ui.MessageWriter.ToolCallBase
--- @field kind agentic.acp.ToolKind
--- @field argument string
--- @field extmark_id? integer Range extmark spanning the block
--- @field decoration_extmark_ids? integer[] IDs of decoration extmarks from ExtmarkBlock
--- @field search_matches? agentic.ui.MessageWriter.SearchMatch[] Pattern match positions (relative to block lines)
--- @field search_ansi? agentic.utils.Ansi.Span[][] ANSI highlight spans for search body
--- @field cached_diff_blocks? agentic.ui.ToolCallDiff.DiffBlock[] Captured at render time so navigation (diff_jump) survives a later file refresh that breaks OLD-based matching
--- @field parent_tool_use_id? string Spawning Task tool id when this call belongs to a subagent; nil for main-agent calls
--- @field trailing_insert_mark_id? integer Zero-width NS_TOOL_BLOCKS mark riding just below the block, marking where the next region anchored to it goes (see `MessageWriter:_anchor_insert_row`). Absent until the first such region.
--- @field highlight_pass? integer Sequence number of the latest scheduled highlight pass. A pass that is no longer the latest skips.
--- @field fold_anchor_id? integer The block's anchor extmark in NS_FOLD_ANCHORS, on the first body row of its foldable fence.
--- @field fold_open? boolean The fold state the renderer wants for the block's current lines.
--- @field fold_sent? boolean The state last queued for the anchor. Nil while the op is deferred.

--- Append the closing fence for `lines` when they leave one open.
---
--- Prose and user prompts reach the chat buffer verbatim; only tool call blocks
--- get `safe_fence` protection. An unclosed ``` leaves `fenced_code_block`
--- unterminated, so it swallows the following prose and tool call blocks up to
--- the next bare ``` line, or to the end of the buffer — taking their
--- highlighting, and any `*-fold` fence opened inside it, with them. Closing it
--- bounds that to the block the model opened.
---
--- Only ever called at the end of a prose run: mid-stream the fence is
--- legitimately open and closing it early would corrupt the render.
--- @param lines string[]
local function close_fence(lines)
    local fence = TextWrap.unclosed_fence(lines)
    if fence then
        lines[#lines + 1] = fence
    end
end

--- @class agentic.ui.MessageWriter.ErrorBlock
--- @field heading_id integer NS_ERROR extmark on the block's `## Error` row — the anchor its rail is re-stamped from. Doubles as the heading's own highlight, so the block costs no mark of its own.
--- @field rail_ids integer[] NS_DECORATIONS marks of the block's `│`/`╰─` rail, freed and re-stamped whole each time the block grows.
--- @field line_count integer Buffer line count the block last ended at. A different count means something else has been written since, so the block is closed and the next action starts on its own.

--- @class agentic.ui.MessageWriter
--- @field bufnr integer
--- @field tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @field _thought_run? string Thinking streamed since the last flush, held back until the run ends because its fence has to reach the buffer in one write (see `flush_thought_run`). Dropped rather than rendered when the widget closes mid-run; the text is in `chat_history`.
--- @field _fold_retry_armed? boolean True while an InsertLeave autocmd is waiting to retry deferred fold ops (see `flush_pending_fold_ops`). Guards against arming a second one per pending batch.
--- @field _scroll_owed boolean True from a write's `_schedule_follow` until a scroll discharges it: `_schedule_follow`'s callback on the non-fold path, `flush_pending_fold_ops` on the fold path. The callback's skip branch leaves it set, so a scroll deferred to the fold-close (or to the BufWinEnter retry when no window exists yet) rides along with its pending fold. The insert-mode hold is the one deferral the callback does not wait on — see the skip condition, which reads `_fold_retry_armed`.
--- @field _scroll_callback_queued? boolean Per-tick coalescing guard — true while a deferred scroll callback is queued this tick. Only prevents double-queuing; says nothing about whether the scroll happens.
--- @field _chunk_start_line? integer 0-indexed buffer line the unreflowed tail of the current prose run starts at; advanced past each paragraph a streaming reflow wraps, and cleared by the flushing one. Read by `_reflow_chunks` to bound its rewrite.
--- @field _prose_anchor_line? integer 0-indexed buffer line of the first non-blank line of the current prose run; pinned at the top of the viewport during streaming and cleared by `_release_prose_pin` and `_clear_prose_pin`
--- @field _pin_held table<integer, true> Windows whose last scroll the prose pin held short of the last line. Set by `_scroll`, and cleared there by a scroll to the held tool call; `_release_prose_pin` hands them to user control.
--- @field _held_tool_call_id? string The tool call whose block following keeps in view instead of the stream (`hold_tool_call`)
--- @field _hold_unplaced boolean The next scroll that resolves the held block's rows places it (`BufHelpers.show_rows`) instead of capping the topline at it
--- @field _prose_run_start_line? integer 0-indexed buffer line where the current prose run began — the row `_chunk_start_line` was first set to, which reflows then advance past each paragraph they wrap. Read by `_end_prose_run` to bracket the run; cleared by every flushing reflow, which is to say wherever a prose run ends.
--- @field _prose_region_ids? integer[] Decoration extmark ids of the live prose run's region signs, in buffer order, so the last one is its `╰─`. Held so a re-stamp can free the signs it replaces, and released in the same statement as `_prose_run_start_line`: a list outliving its run would have the next run's first re-stamp delete a committed bracket.
--- @field _views table<integer, agentic.ui.MessageWriter.View> Per window, the last view seen, recorded by `_own_change` and at each view change. `on_view_change` reads the user's motion as the difference from it.
--- @field _entered_window? integer The window that just became current, whose next view change is the entry and not a motion
--- @field _user_controlled table<integer, true> Windows in user control, which writes do not scroll; every other window follows. Survives turn boundaries.
--- @field _has_last_position boolean Whether the last window the buffer left, as no other window showed it, was in user control, and no window has shown the buffer since. False after `new` and `reset`. While false, the `"` mark stays on the last line, and a window that newly shows the buffer opens at the follow target.
--- @field _newly_shown table<integer, true> Following windows that newly show the buffer, whose next scroll starts from the top: vim restores such a window's cursor from its history after BufWinEnter, possibly below the follow target, and `BufHelpers.scroll_down` never scrolls up. Cleared by that scroll, or when the window goes to user control.
--- @field _pending_fold_ops { id: integer, open: boolean }[] Fold ops (anchor extmark id in NS_FOLD_ANCHORS + desired state) for `*-fold`/`-difffold` fences rendered while no chat window was visible. Flushed when a window shows the buffer again: its BufWinEnter, or for widget windows (opened without autocmds) `ChatWidget.on_window_opened`. `open=false` closes (sidecars, rejected edits); `open=true` opens (applied edit diffs) — the explicit open both honours the diff's open-by-default and neutralises the foldexpr leak whereby a fold created after a closed one inherits the closed state.
--- @field _home_window? fun(): integer|nil The window hard wrap measures while it shows the buffer
--- @field _fold_states table<integer, boolean> Applied fold ops, anchor extmark id in NS_FOLD_ANCHORS -> open. Replayed in each window that starts showing the buffer (see `replay_folds`).
--- @field _pending_section_break? boolean Set by `_mark_section_break` when a tool call interrupts a prose run mid-turn; makes the next prose chunk emit the empty `###` boundary that closes the interrupting section. Cleared by that chunk and at the turn boundary.
--- @field _error_block? agentic.ui.MessageWriter.ErrorBlock The `## Error` region still open at the end of the buffer, which `write_error_action` extends. Not per-turn state: the line-count check on `ErrorBlock` is what closes it, and it closes a block against a mid-turn write too, which a turn-boundary reset would miss.
local MessageWriter = {}
MessageWriter.__index = MessageWriter

--- Namespace for user-action marker extmarks: placed at write time on the
--- heading line of each user prompt (`write_user_prompt`) and each command
--- notice (`write_notice`). Drives both the row's identity sign and `[[`/`]]`
--- navigation, replacing the old text-scan on `line == "##"` (dead since the
--- heading became `## <first line>`). Global namespace + buffer-scoped marks is
--- sanctioned by .claude/rules/multi-tabpage.md (mirrors Renderer.NS_TOOL_BLOCKS).
MessageWriter.NS_USER_ACTIONS =
    vim.api.nvim_create_namespace("agentic_user_actions")

--- Forget everything written to the buffer, for a buffer whose text is gone
--- or about to be rewritten whole: the tool call trackers, any error region
--- left open, the pending fold ops, the per-turn state, and every extmark in
--- the buffer.
---
--- Emptying or reloading a buffer collapses extmarks onto row 0 rather than
--- deleting them, so a tracker or mark surviving its text resolves to the top
--- of what replaces it — `[[`/`]]` jump to a phantom prompt, rail signs pile
--- on row 0, and anything anchored to a stale tracker is inserted there. Every
--- namespace is cleared, the status indicator's and the fold anchors'
--- included: none of them outlives the text it marks.
function MessageWriter:reset()
    self.tool_call_blocks = {}
    self._error_block = nil
    self._pending_fold_ops = {}
    self._fold_states = {}
    self._has_last_position = false
    self:reset_turn_state()
    vim.api.nvim_buf_clear_namespace(self.bufnr, -1, 0, -1)
end

--- @param bufnr integer
--- @param home_window (fun(): integer|nil)|nil The window hard wrap measures whenever it shows the buffer (see `_wrap_window`)
--- @return agentic.ui.MessageWriter
function MessageWriter:new(bufnr, home_window)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Invalid buffer number: " .. tostring(bufnr))
    end

    local instance = setmetatable({
        bufnr = bufnr,
        _home_window = home_window,
        tool_call_blocks = {},
        _thought_run = nil,
        _fold_retry_armed = false,
        _scroll_owed = false,
        _scroll_callback_queued = false,
        _chunk_start_line = nil,
        _prose_run_start_line = nil,
        _prose_region_ids = nil,
        _pending_section_break = false,
        _prose_anchor_line = nil,
        _pin_held = {},
        _hold_unplaced = false,
        _views = {},
        _entered_window = nil,
        _user_controlled = {},
        _has_last_position = false,
        _newly_shown = {},
        _pending_fold_ops = {},
        _fold_states = {},
    }, self)

    -- Listen for the user's scrolls and cursor motions. WinScrolled is not
    -- buffer-scoped: that matches only the first scrolled window's buffer, and
    -- every scrolled window is a key of `v:event`. The group goes with the
    -- buffer.
    local group = vim.api.nvim_create_augroup(
        "agentic_message_writer_" .. bufnr,
        { clear = true }
    )
    vim.api.nvim_create_autocmd("WinEnter", {
        group = group,
        buffer = bufnr,
        callback = function()
            instance:on_window_enter(vim.api.nvim_get_current_win())
        end,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
        group = group,
        buffer = bufnr,
        callback = function()
            instance:on_window_leave(vim.api.nvim_get_current_win())
        end,
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        buffer = bufnr,
        callback = function()
            instance:on_view_change(vim.api.nvim_get_current_win(), false)
        end,
    })
    vim.api.nvim_create_autocmd("WinScrolled", {
        group = group,
        callback = function()
            for key, change in pairs(vim.v.event) do
                local winid = tonumber(key)
                if
                    winid
                    and vim.api.nvim_win_is_valid(winid)
                    and vim.api.nvim_win_get_buf(winid) == bufnr
                then
                    instance:on_view_change(
                        winid,
                        change.width ~= 0 or change.height ~= 0
                    )
                end
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWinLeave", {
        group = group,
        buffer = bufnr,
        callback = function()
            instance:on_last_window_leave()
        end,
    })
    -- Not buffer-scoped: a closed window may show another buffer by then.
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
            instance:on_window_closed(tonumber(args.match) --[[@as integer]])
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        once = true,
        callback = function()
            vim.api.nvim_del_augroup_by_id(group)
        end,
    })

    -- Fold state is window-local. A fold rendered while no window showed the
    -- buffer never got its initial open/close, and a window opened later has
    -- none of the applied ones: give this window every recorded state, then
    -- apply the pending ops, whose flush scrolls against the folds as they
    -- end up.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            local winid = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_buf(winid) == bufnr then
                instance:on_window_shown(winid)
                instance:replay_folds(winid)
            end
            instance:flush_pending_fold_ops()
        end,
    })

    return instance
end

--- @class agentic.ui.MessageWriter.View
--- @field topline integer After the correction vim would otherwise make at the next redraw ('scrolloff', a cursor outside the view)
--- @field lnum integer The cursor line
--- @field rows integer Screen rows of text from the topline through the last line, virtual lines not counted; capped at one past the window height
--- @field shows_end boolean Whether the last line is in view
--- @field on_last_line boolean Whether the cursor is on the last line, or on a closed fold that ends there

--- The view of `winid`.
--- @param winid integer
--- @return agentic.ui.MessageWriter.View
local function view_of(winid)
    return vim.api.nvim_win_call(winid, function()
        -- line("w0") applies the redraw's correction first.
        local topline = vim.fn.line("w0")
        local lnum = vim.api.nvim_win_get_cursor(winid)[1]
        local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))
        local height = vim.api.nvim_win_text_height(winid, {
            start_row = topline - 1,
            end_row = last - 1,
            max_height = vim.api.nvim_win_get_height(winid) + 1,
        })
        --- @type agentic.ui.MessageWriter.View
        local view = {
            topline = topline,
            lnum = lnum,
            rows = height.all - height.fill,
            shows_end = vim.fn.line("w$") >= last,
            on_last_line = math.max(lnum, vim.fn.foldclosedend(lnum)) == last,
        }
        return view
    end)
end

--- WinEnter hook. The next view change in `winid`, the one the entry causes
--- (a cursor placed by a click, say), only records the view. Public so the
--- autocmd closure can reach it without tripping LuaLS's invisible-field check.
--- @param winid integer The entered window
function MessageWriter:on_window_enter(winid)
    self._entered_window = winid
end

--- WinLeave hook: an entry that caused no view change before the window was
--- left leaves nothing to skip. Public so the autocmd closure can reach it
--- without tripping LuaLS's invisible-field check.
--- @param winid integer The left window
function MessageWriter:on_window_leave(winid)
    if self._entered_window == winid then
        self._entered_window = nil
    end
end

--- BufWinEnter and widget-open hook: decide the mode of a window that newly
--- shows the buffer. With a last position, it goes to user control and keeps
--- its place, and the buffer's last position is used up. Without one, it
--- follows, and the next scroll takes it from the top to the follow target.
--- With `follow.enabled` off, it goes to the last line instead. Call it
--- synchronously, before `flush_pending_fold_ops` scrolls the following
--- windows. Public so the autocmd closure and `SessionManager` can reach it
--- without tripping LuaLS's invisible-field check.
--- @param winid integer A window showing the buffer
function MessageWriter:on_window_shown(winid)
    -- The view vim's cursor restore leaves is then no motion up.
    self:_own_change(function() end)
    if self._has_last_position then
        self._has_last_position = false
        self._user_controlled[winid] = true
        return
    end
    if Config.follow and Config.follow.enabled == false then
        self:go_to_bottom(winid)
        return
    end
    self._newly_shown[winid] = true
    self:follow_in(winid)
end

--- BufWinLeave hook: the buffer leaves its last window. Left in user control,
--- the buffer keeps the last position vim put in `"`. Left following, it has
--- none, and `"` goes back to the last line. Public so the autocmd closure
--- can reach it without tripping LuaLS's invisible-field check.
function MessageWriter:on_last_window_leave()
    -- The leaving window still shows the buffer.
    local winid = vim.fn.win_findbuf(self.bufnr)[1]
    self._has_last_position = winid ~= nil
        and self._user_controlled[winid] == true
    self:_mark_last_line()
    if winid then
        self:_forget_window(winid)
    end
end

--- WinClosed hook: forget the state kept for `winid`. The buffer's last
--- window is left to `on_last_window_leave`, whose BufWinLeave comes after
--- WinClosed and reads that state. Public so the autocmd closure can reach
--- it without tripping LuaLS's invisible-field check.
--- @param winid integer The closing window
function MessageWriter:on_window_closed(winid)
    local winids = vim.fn.win_findbuf(self.bufnr)
    if not (#winids == 1 and winids[1] == winid) then
        self:_forget_window(winid)
    end
end

--- Drop every per-window entry of `winid`.
--- @param winid integer
function MessageWriter:_forget_window(winid)
    self._user_controlled[winid] = nil
    self._views[winid] = nil
    self._pin_held[winid] = nil
    self._newly_shown[winid] = nil
    if self._entered_window == winid then
        self._entered_window = nil
    end
end

--- Put the `"` mark on the last line while the buffer has no last position.
function MessageWriter:_mark_last_line()
    if self._has_last_position or not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end
    local last = vim.api.nvim_buf_line_count(self.bufnr)
    vim.api.nvim_buf_set_mark(self.bufnr, '"', last, 0, {})
end

--- WinScrolled and CursorMoved hook. Reads the user's motion in `winid` as
--- the difference from the last view seen there, and sets its mode by the
--- direction:
---
--- - Cursor on the last line, or on a closed fold that ends there → following.
--- - Up: more rows of text from the topline to the end, or as many with the
---   cursor moved up → user control.
--- - View down, with the last line now in view → following.
---
--- Any other change keeps the mode. A resize, the change a window entry
--- causes, and the first change seen in a window only record the view. Our
--- own changes leave no difference: `_own_change` records the view they
--- leave. Public so the autocmd closure can reach it without tripping LuaLS's
--- invisible-field check.
--- @param winid integer A window showing the buffer
--- @param resized boolean Whether the window changed size
function MessageWriter:on_view_change(winid, resized)
    local view = view_of(winid)
    local before = self._views[winid]
    self._views[winid] = view
    local entered = self._entered_window == winid
    if entered then
        self._entered_window = nil
    end
    if resized or entered or not before or vim.deep_equal(view, before) then
        return
    end

    local up = view.rows > before.rows
        or (view.rows == before.rows and view.lnum < before.lnum)
    local down_to_end = not up
        and view.topline > before.topline
        and view.shows_end
    if view.on_last_line or down_to_end then
        self._user_controlled[winid] = nil
    elseif up then
        self._user_controlled[winid] = true
        self._newly_shown[winid] = nil
    end
end

--- Put `winid` in following, with its cursor and view on the last line.
--- @param winid integer A window showing the buffer
function MessageWriter:go_to_bottom(winid)
    self._user_controlled[winid] = nil
    self:_own_change(function()
        vim.api.nvim_win_call(winid, function()
            vim.cmd("normal! G")
        end)
    end)
end

--- Run `fn` and record the view it leaves in each window showing the buffer,
--- so the view events it causes read as no motion.
--- @generic T
--- @param fn fun(): T|nil
--- @return T|nil result What `fn` returned
function MessageWriter:_own_change(fn)
    local result = fn()
    for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
        self._views[winid] = view_of(winid)
    end
    return result
end

--- Put every window showing the buffer in following and scroll each now, as a
--- write would, not at the next write. A held tool call is placed again.
function MessageWriter:resume_follow()
    self._user_controlled = {}
    self._hold_unplaced = self._held_tool_call_id ~= nil
    self:_scroll(vim.fn.win_findbuf(self.bufnr))
end

--- Keep a tool call's block in view of the following windows, instead of
--- the stream, until `release_hold`: place it, then cap the topline at its
--- header line. User motion does not end the hold.
--- @param tool_call_id string
function MessageWriter:hold_tool_call(tool_call_id)
    self._held_tool_call_id = tool_call_id
    self._hold_unplaced = true
    self:_schedule_follow()
end

--- End the hold of `hold_tool_call`: the following windows follow the stream
--- again. A no-op when nothing is held.
function MessageWriter:release_hold()
    if not self._held_tool_call_id then
        return
    end
    self._held_tool_call_id = nil
    self._hold_unplaced = false
    self:_schedule_follow()
end

--- Put `winid` in following and scroll the following windows, placing a held
--- tool call again in each of them, `winid` or not: one the user moved down
--- past the block moves back to it.
--- @param winid integer A window showing the buffer
function MessageWriter:follow_in(winid)
    self._user_controlled[winid] = nil
    self._hold_unplaced = self._held_tool_call_id ~= nil
    self:_schedule_follow()
end

--- Whether any window showing the buffer follows writes, or none shows it.
--- @return boolean
function MessageWriter:any_following()
    local winids = vim.fn.win_findbuf(self.bufnr)
    for _, winid in ipairs(winids) do
        if not self._user_controlled[winid] then
            return true
        end
    end
    return #winids == 0
end

--- End the prose pin. A window the pin held short of the last line goes to
--- user control, so the prose it shows stays in view; every other window
--- keeps its mode.
--- @private
function MessageWriter:_release_prose_pin()
    for winid in pairs(self._pin_held) do
        if
            vim.api.nvim_win_is_valid(winid)
            and vim.api.nvim_win_get_buf(winid) == self.bufnr
        then
            self._user_controlled[winid] = true
        end
    end
    self:_clear_prose_pin()
end

--- Drop the prose pin without handing any window to user control.
--- @private
function MessageWriter:_clear_prose_pin()
    self._prose_anchor_line = nil
    self._pin_held = {}
end

--- Make the next prose chunk of this turn open its own section, by emitting the
--- empty `###` boundary ahead of it (see `write_message_chunk`). Called by the
--- tool call writer — the only writer that interrupts a prose run with a
--- section markdown cannot otherwise close (`##` writers close their own).
--- @private
function MessageWriter:_mark_section_break()
    self._pending_section_break = true
end

--- Drop the live prose run without bracketing it: its tracking, its reflow
--- marker and its signs. The counterpart of `_end_prose_run`, for a run whose
--- rows are gone or are being abandoned mid-stream.
---
--- The signs go with the run, not just the tracking: the next run starts on the
--- row they end on, where a surviving `╰─` would contend with its `╭─` for the
--- one sign cell.
--- @param bufnr integer
--- @private
function MessageWriter:_abandon_prose_run(bufnr)
    self._chunk_start_line = nil
    self._prose_run_start_line = nil
    Renderer.clear_decoration_extmarks(bufnr, self._prose_region_ids)
    self._prose_region_ids = nil
end

--- Reset all per-turn mutable state. Called by refresh to unstick a
--- desynchronised display without restarting the session.
function MessageWriter:reset_turn_state()
    self._pending_section_break = false
    self:_abandon_prose_run(self.bufnr)
    self._thought_run = nil
    self:_clear_prose_pin()
end

--- Run `fn` on the buffer made modifiable, as an `_own_change`.
---
--- Every chat-buffer visual mutation routes through here, so this single
--- choke also forces the repaint neovim otherwise defers while a command-line
--- is open (see `BufHelpers.redraw_if_cmdline`), keeping streamed updates live
--- behind `:`. In every other mode that repaint is a no-op — the write lands
--- on screen at neovim's automatic pre-input redraw.
---
--- Rendering loses nothing, so `modified` is left as it was before the write:
--- the flag belongs to the buffer's owner.
--- @param fn fun(bufnr: integer): boolean|nil
--- @return boolean|nil result What `fn` returned; false for an invalid buffer or an error
function MessageWriter:_own_edit(fn)
    local result = self:_own_change(function()
        local was_modified = vim.api.nvim_buf_is_valid(self.bufnr)
            and vim.bo[self.bufnr].modified
        local written = BufHelpers.with_modifiable(self.bufnr, fn)
        if vim.api.nvim_buf_is_valid(self.bufnr) then
            vim.bo[self.bufnr].modified = was_modified
        end
        return written
    end)
    self:_mark_last_line()
    BufHelpers.redraw_if_cmdline()
    return result
end

--- The window hard wrap measures, the one width the buffer's text can have:
--- the home window while it shows the buffer, else the first window showing
--- it in the current tabpage. A narrow window opened elsewhere then does not
--- narrow the wrap for good.
--- @return integer|nil winid
function MessageWriter:_wrap_window()
    local home = self._home_window and self._home_window()
    if
        home
        and vim.api.nvim_win_is_valid(home)
        and vim.api.nvim_win_get_buf(home) == self.bufnr
    then
        return home
    end
    local winid = vim.fn.bufwinid(self.bufnr)
    return winid ~= -1 and winid or nil
end

--- Returns the text area width of the wrap window (excluding sign column),
--- or 80 when there is none (see `_wrap_window`). The chat window
--- always has signcolumn=yes:1 (2 columns).
--- Clamped to `Config.windows.{min,max}_wrap_width` (either 0 disables that
--- bound). The floor wins against a narrow *window* — prose keeps wrapping at
--- `min_wrap_width` and is clipped at the window edge (the chat window is
--- `nowrap`) rather than being shredded into two-word lines — but never against
--- a configured `max_wrap_width`, which stays an absolute ceiling.
--- Returns 0 when the chat window has soft wrap enabled (no hard wrapping needed).
--- @return integer
function MessageWriter:_get_wrap_width()
    local winid = self:_wrap_window()
    if winid and vim.wo[winid].wrap then
        return 0
    end
    local width
    if winid then
        width = vim.api.nvim_win_get_width(winid) - 2
    else
        width = 80
    end
    local max = Config.windows.max_wrap_width
    local min = Config.windows.min_wrap_width
    if max > 0 then
        width = math.min(width, max)
        min = math.min(min, max)
    end
    if min > 0 then
        width = math.max(width, min)
    end
    return width
end

--- Writes a full message to the chat buffer and append two blank lines after.
--- Prose lines are hard-wrapped to the chat window width; code blocks are untouched.
--- @param update agentic.acp.SessionUpdateMessage
function MessageWriter:write_message(update)
    local text = update.content
        and update.content.type == "text"
        and update.content.text --[[@as string]]

    if not text or text == "" then
        return
    end

    -- Thinking that preceded this message has to land above it. Replay reaches
    -- here for every stored agent message, and stores thoughts separately.
    self:flush_thought_run()

    local lines = vim.split(text, "\n", { plain = true })
    close_fence(lines)
    lines = TextWrap.wrap_prose(lines, self:_get_wrap_width())

    self:_schedule_follow()

    self:_own_edit(function()
        self:_append_lines(lines)
        self:_append_lines({ "" })
    end)
end

--- Build the chat-buffer lines for a user prompt: the first line becomes the
--- `## ` heading (so treesitter-context pins it as the turn's breadcrumb),
--- remaining lines follow as body.
--- @param text string Raw prompt text
--- @return string[] lines
local function prompt_heading_lines(text)
    local prompt_lines = vim.split(text, "\n", { plain = true })
    local lines = { "## " .. prompt_lines[1] }
    for i = 2, #prompt_lines do
        table.insert(lines, prompt_lines[i])
    end
    return lines
end

--- The row a region's `╰─` belongs on: the last row of `first_row .. last_row`
--- that draws the corner where it can be seen.
---
--- A trailing blank row has nothing to close over, and a fence delimiter is
--- concealed to zero height (`TextWrap.is_fence_delimiter`), so a corner
--- anchored on either is at best detached from the region's last content and at
--- worst never drawn, leaving the region to read as unterminated. A prompt ends
--- on a delimiter whenever it carries selected code, or whenever `close_fence`
--- had to balance one the user left open. Interior rows of both kinds need no
--- such care: a zero-height row leaves no gap in the rail.
--- @param bufnr integer
--- @param first_row integer 0-indexed opening row of the region
--- @param last_row integer 0-indexed last row of the region, inclusive
--- @return integer row `first_row` when nothing below it draws, and less than
---         that for a range past the end of the buffer — both leave the caller's
---         one-drawn-row check to reject the region
local function last_drawn_row(bufnr, first_row, last_row)
    local rows =
        vim.api.nvim_buf_get_lines(bufnr, first_row, last_row + 1, false)
    local last = #rows
    while
        last > 1
        and (
            rows[last]:match("^%s*$")
            or TextWrap.is_fence_delimiter(rows[last])
        )
    do
        last = last - 1
    end
    return first_row + last - 1
end

--- The first row of `from_row .. to_row` carrying prose, or nil when none does.
--- Skips blanks and the empty `###` section boundary that opens a prose run
--- resuming after an interrupting block (see `write_message_chunk`), neither of
--- which is text the reader is looking at.
--- @param bufnr integer
--- @param from_row integer 0-indexed row to start scanning at
--- @param to_row integer 0-indexed last row to scan, inclusive
--- @return integer|nil
local function first_prose_row(bufnr, from_row, to_row)
    local rows = vim.api.nvim_buf_get_lines(bufnr, from_row, to_row + 1, false)
    for i, content in ipairs(rows) do
        if content:match("%S") and not content:match("^#+%s*$") then
            return from_row + i - 1
        end
    end
    return nil
end

--- True when a blank row falls strictly between `from_row` and `to_row` — that
--- is, when the rows hold more than one paragraph.
---
--- Only the interior counts. A run's leading and trailing breaks are stripped by
--- `first_prose_row` and `last_drawn_row` before this sees the range, and say
--- nothing about how much the run holds.
--- @param bufnr integer
--- @param from_row integer 0-indexed first row of the range
--- @param to_row integer 0-indexed last row of the range, inclusive
--- @return boolean
local function has_paragraph_break(bufnr, from_row, to_row)
    -- Fewer than three rows cannot hold an interior blank.
    if to_row - from_row < 2 then
        return false
    end
    local rows = vim.api.nvim_buf_get_lines(bufnr, from_row + 1, to_row, false)
    for _, content in ipairs(rows) do
        if content:match("^%s*$") then
            return true
        end
    end
    return false
end

--- Stamp the `│`/`╰─` rail under a region whose identity sign is already in
--- place, marking how far the region reaches.
---
--- The rail goes in the decoration namespace even though the identity sign does
--- not: `[[`/`]]` stops on every mark in NS_USER_ACTIONS, so a body-row mark
--- there would land the cursor inside a region instead of on its opening row.
---
--- A region with one drawn row gets nothing — it carries the identity sign
--- alone. The chat window is `signcolumn=yes:1`, so a `╰─` on that row would
--- contend with the identity for the one sign cell.
--- @param bufnr integer
--- @param identity_row integer 0-indexed row carrying the identity sign
--- @param last_row integer 0-indexed last row of the region, inclusive
--- @return integer[] decoration_extmark_ids Empty for a region drawing one row
local function render_region_rail(bufnr, identity_row, last_row)
    local end_row = last_drawn_row(bufnr, identity_row, last_row)
    if end_row <= identity_row then
        return {}
    end
    return ExtmarkBlock.render_rail(bufnr, Renderer.NS_DECORATIONS, {
        body_start = identity_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- Bracket the prose run reaching from `run_start` to the end of the buffer:
--- `╭─` on its first row of text, `│` beneath, `╰─` on its last drawn row.
---
--- Prose is the one region with nothing to announce, so it opens on the plain
--- corner instead of an identity glyph.
---
--- Only a run holding more than one paragraph is bracketed: a rail over a
--- one-line aside between tool calls groups nothing, and those asides are a
--- third of every run written. The measure is a blank row inside the run rather
--- than a row count, which is a property of the window instead of the text —
--- `_get_wrap_width` returns 0 under `wrap`, where a paragraph of any length is
--- one row, so a row count would have the same reply bracket in one split width
--- and not in another.
---
--- `run_start` is where the chunk writer began appending, which sits a row or
--- two above the first word: the run can open on a blank or on the `###`
--- boundary that closes an interrupting block's section. Neither belongs to the
--- region. The heading is an artifact of ATX headings closing a section by
--- opening the next, carries no content, and exists for the block above it (see
--- `write_message_chunk`) — and the viewport pin sits on the first row of text
--- (`_prose_anchor_line`), so a corner above that row is scrolled out of sight
--- for the whole of the run's streaming.
--- @param bufnr integer
--- @param run_start integer 0-indexed row where the prose run began
--- @return integer[]|nil decoration_extmark_ids nil when the run takes no region
local function render_prose_region(bufnr, run_start)
    local buf_end = vim.api.nvim_buf_line_count(bufnr) - 1
    local first_row = first_prose_row(bufnr, run_start, buf_end)
    if not first_row then
        return nil
    end

    local end_row = last_drawn_row(bufnr, first_row, buf_end)
    if not has_paragraph_break(bufnr, first_row, end_row) then
        return nil
    end

    return ExtmarkBlock.render_block(bufnr, Renderer.NS_DECORATIONS, {
        header_line = first_row,
        header_sign = ExtmarkBlock.SIGNS.HEADER,
        body_start = first_row + 1,
        body_end = end_row - 1,
        footer_line = end_row,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- Stamp a collapsed region's signs: its identity glyph on the first body row,
--- the `│`/`╰─` rail beneath. That row is also the row a closed fold shows, so
--- the gutter names the region whether it is collapsed or open.
--- @param bufnr integer
--- @param first_row integer 0-indexed first body row of the region
--- @param last_row integer 0-indexed last body row of the region, inclusive
--- @param sign string `sign_text` identifying the region
local function render_collapsed_region(bufnr, first_row, last_row, sign)
    local end_row = last_drawn_row(bufnr, first_row, last_row)
    ExtmarkBlock.render_block(bufnr, Renderer.NS_DECORATIONS, {
        header_line = first_row,
        header_sign = sign,
        header_hl_group = Theme.HL_GROUPS.GLYPH_AGENT,
        body_start = first_row + 1,
        body_end = end_row - 1,
        footer_line = end_row > first_row and end_row or nil,
        hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
    })
end

--- Stamp the live prose run's region from scratch, replacing the signs it
--- already carries.
---
--- Signs do not survive the `set_lines` a reflow runs over the run's rows — they
--- collapse onto the replacement's first row — so a rewritten run is rebuilt
--- rather than repaired, the same way a resized tool call block is. A run that
--- holds a single paragraph tracks nil and stamps nothing.
--- @param bufnr integer
function MessageWriter:_rebuild_prose_region(bufnr)
    if not self._prose_run_start_line then
        return
    end
    Renderer.clear_decoration_extmarks(bufnr, self._prose_region_ids)
    self._prose_region_ids =
        render_prose_region(bufnr, self._prose_run_start_line)
end

--- Move the live run's `╰─` down to the last row the run has grown, rewriting
--- the row it used to close on to `│`.
---
--- The rail has to follow every row gained, not every paragraph: a reflow fires
--- only once a paragraph completes, so a corner left where the last one ended
--- sits mid-region with bare rows beneath it. Rewriting the old corner in place
--- rather than re-stamping the whole run is what makes that cadence cheap.
---
--- Rebuilds instead for a run carrying no region yet — the rows just written may
--- be what carries it past a single paragraph.
--- @param bufnr integer
function MessageWriter:_extend_prose_region(bufnr)
    local ids = self._prose_region_ids
    local closer_id = ids and ids[#ids]
    local closer_row = closer_id
        and vim.api.nvim_buf_get_extmark_by_id(
            bufnr,
            Renderer.NS_DECORATIONS,
            closer_id,
            {}
        )[1]
    if not ids or not closer_id or not closer_row then
        -- No region yet, or its marks went with a buffer-wide clear
        -- (`reset`) — a dead id deletes as a no-op either way.
        self:_rebuild_prose_region(bufnr)
        return
    end

    local end_row = last_drawn_row(
        bufnr,
        closer_row,
        vim.api.nvim_buf_line_count(bufnr) - 1
    )
    if end_row <= closer_row then
        return
    end

    Renderer.restamp_border(
        bufnr,
        closer_id,
        closer_row,
        ExtmarkBlock.SIGNS.BODY
    )
    -- Appended in buffer order, which is the indexing `render_block` documents
    -- and which locating the corner above depends on.
    vim.list_extend(
        ids,
        ExtmarkBlock.render_rail(bufnr, Renderer.NS_DECORATIONS, {
            body_start = closer_row + 1,
            body_end = end_row - 1,
            footer_line = end_row,
            hl_group = Theme.HL_GROUPS.CODE_BLOCK_FENCE,
        })
    )
end

--- End the prose run at the end of the buffer: reflow what is left of it,
--- bracket it, and release the run.
---
--- The one way a run ends. Every writer that interrupts prose calls this rather
--- than the flushing reflow directly, so a run cannot be released without being
--- bracketed, nor bracketed twice.
--- @param bufnr integer
function MessageWriter:_end_prose_run(bufnr)
    local run_start = self._prose_run_start_line
    -- The reflow can rewrite the run's rows and append a closing fence, moving
    -- both ends of the region, so the final bracket is stamped fresh. Its ids go
    -- untracked: the region is finished, and holding them would have the next
    -- run's first re-stamp delete it.
    Renderer.clear_decoration_extmarks(bufnr, self._prose_region_ids)
    self:_reflow_chunks(bufnr, true)
    if run_start then
        render_prose_region(bufnr, run_start)
    end
end

--- The lines of a collapsed region: the body inside a `markdown-fold` fence
--- closed at render, followed by the blank that separates it from what comes
--- after. The fence delimiters conceal to zero height, so the region occupies
--- the single screen row its foldtext summarises (`agentic.ui.folds`).
---
--- A body too short to fold — vim cannot close a one-line fold — is emitted as
--- that line alone, with no fence: a visible ``` around one line is worse than
--- the line itself. `source` goes with it, having no foldtext to name.
--- @param body string[] Already prose-wrapped
--- @param source string|nil Where the body came from, for the foldtext to name
--- @param section_break boolean Open with the empty `###` that closes the section of the block above
--- @return string[] lines
--- @return integer body_offset 0-indexed offset of the first body row within `lines`
local function collapsed_region_lines(body, source, section_break)
    local lines = {}
    if section_break then
        vim.list_extend(lines, { "###", "" })
    end

    local fence = #body > 1 and Renderer.safe_fence(body) or nil
    if fence then
        -- `source` as a second word after the language: `folds.scm` and
        -- `injections.scm` both key on the `(info_string (language))` node,
        -- which is the first word alone, so the name rides along without
        -- disturbing either.
        lines[#lines + 1] = fence
            .. "markdown-fold"
            .. (source and (" " .. source) or "")
    end

    local body_offset = #lines
    vim.list_extend(lines, body)
    if fence then
        lines[#lines + 1] = fence
    end
    lines[#lines + 1] = ""
    return lines, body_offset
end

--- Stamp a collapsed region already in the buffer: `sign` on its first body
--- row, the rail beneath, the whole body dimmed, and the fold closed when the
--- body has one.
--- @param bufnr integer
--- @param body_start integer 0-indexed first body row of the region
--- @param body_end integer 0-indexed last body row of the region, inclusive
--- @param sign string `sign_text` identifying the region
function MessageWriter:_decorate_collapsed_region(
    bufnr,
    body_start,
    body_end,
    sign
)
    render_collapsed_region(bufnr, body_start, body_end, sign)
    Renderer.set_dim_range(bufnr, body_start, body_end)
    -- Same measure `collapsed_region_lines` folds on: a one-row body has no
    -- fence, and so no fold to close.
    if body_end > body_start then
        self:_close_fold(body_start)
    end
end

--- Append a body as one collapsed region at the end of the chat buffer.
--- @param body string[] Already prose-wrapped
--- @param sign string `sign_text` identifying the region
--- @param source string|nil Where the body came from, for the foldtext to name
function MessageWriter:_write_collapsed_region(body, sign, source)
    if #body == 0 then
        return
    end

    -- A region after a tool call closes that call's section, for the reason
    -- `write_message_chunk` documents: the fence below would otherwise keep the
    -- breadcrumb on the tool call for as long as the region is on screen.
    local lines, body_offset =
        collapsed_region_lines(body, source, self._pending_section_break)
    self._pending_section_break = false

    -- A collapsed region ends the prose run it follows, so the viewport stops
    -- being anchored to prose the reader has already passed.
    self:_release_prose_pin()
    self:_schedule_follow()

    self:_own_edit(function(bufnr)
        -- End the prose run first, for the reason write_user_prompt documents:
        -- the fence would otherwise land inside one the streamed prose left
        -- open, and a later reflow's set_lines would span these rows and drag
        -- their signs.
        self:_end_prose_run(bufnr)

        self:_append_lines(lines)

        -- Derived from the line count AFTER the append: on an empty buffer
        -- _append_lines replaces row 0 rather than appending, so a row captured
        -- before the call would be off by one.
        local placed_at = vim.api.nvim_buf_line_count(bufnr) - #lines
        self:_decorate_collapsed_region(
            bufnr,
            placed_at + body_offset,
            placed_at + body_offset + #body - 1,
            sign
        )
    end)
end

--- Follow the rows tracking the live prose run across an insertion above them.
---
--- The degenerate case of `shift_across_block`: an insert swallows nothing, so
--- every row at or after `row` moves by `delta` and the prose pin never has to
--- be released. Region signs, fold anchors and block extmarks need no help —
--- they move with their lines.
--- @param row integer 0-indexed first row the insertion displaces
--- @param delta integer number of lines inserted
function MessageWriter:_shift_prose_rows_below(row, delta)
    local function shifted(value)
        if value and value >= row then
            return value + delta
        end
        return value
    end
    self._chunk_start_line = shifted(self._chunk_start_line)
    self._prose_run_start_line = shifted(self._prose_run_start_line)
    self._prose_anchor_line = shifted(self._prose_anchor_line)
end

--- The row a region belonging to `tracker`'s tool call goes on: below the
--- block, and below anything already anchored there.
---
--- The block's range extmark ends on its status-footer row and the blank
--- separating it from what follows is appended after that extmark is set
--- (`write_tool_call_block`), so the first row past the block is two below its
--- end. From then on `trailing_insert_mark_id` answers instead: the range
--- extmark does not move for an insert below it, so a second record would
--- otherwise land above the first and reverse transcript order.
--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
--- @return integer|nil row 0-indexed, nil when the block's range is unusable
function MessageWriter:_anchor_insert_row(tracker)
    local row
    if tracker.trailing_insert_mark_id then
        row = vim.api.nvim_buf_get_extmark_by_id(
            self.bufnr,
            Renderer.NS_TOOL_BLOCKS,
            tracker.trailing_insert_mark_id,
            {}
        )[1]
    end

    if not row and tracker.extmark_id then
        local pos = vim.api.nvim_buf_get_extmark_by_id(
            self.bufnr,
            Renderer.NS_TOOL_BLOCKS,
            tracker.extmark_id,
            { details = true }
        )
        local start_row = pos[1]
        local end_row = pos[3] and pos[3].end_row
        -- The same sanity gate `update_tool_call_block` gives the range, for
        -- the same reason: a collapsed range addresses rows that are no longer
        -- the block's.
        if start_row and end_row and start_row < end_row then
            row = end_row + 2
        end
    end

    if not row or row > vim.api.nvim_buf_line_count(self.bufnr) then
        return nil
    end
    return row
end

--- Insert a body as one collapsed region directly beneath the tool call it
--- belongs to, rather than wherever the buffer happens to end.
---
--- Three steps of the append path are deliberately skipped. `_end_prose_run`
--- and `_release_prose_pin`: the run below a mid-buffer insert is still live,
--- and an inserted region follows nothing, so releasing the pin would discard a
--- viewport promise about unrelated content. `_pending_section_break`: the flag
--- names the most recently written block, which for a mid-buffer insert is not
--- the anchor, so the `###` is decided from the anchor instead — the layout
--- still reproduces the append path's byte for byte.
--- @param body string[] Already prose-wrapped
--- @param sign string `sign_text` identifying the region
--- @param source string|nil Where the body came from, for the foldtext to name
--- @param tool_call_id string The call the region belongs to
--- @return boolean placed False when the anchor is unusable and the caller should append instead
function MessageWriter:_insert_collapsed_region(
    body,
    sign,
    source,
    tool_call_id
)
    local tracker = self.tool_call_blocks[tool_call_id]
    if #body == 0 or not tracker then
        return false
    end
    local insert_row = self:_anchor_insert_row(tracker)
    if not insert_row then
        return false
    end

    -- Only the first region under a block opens a section boundary: the second
    -- follows one that already closed the block's `###` section.
    local lines, body_offset = collapsed_region_lines(
        body,
        source,
        tracker.trailing_insert_mark_id == nil
    )

    -- Nothing has been written under the anchor, so this region lands exactly
    -- where the pending break would have gone and its own `###` serves it.
    -- Leaving the flag set would have the next prose chunk emit a second one.
    if insert_row == vim.api.nvim_buf_line_count(self.bufnr) then
        self._pending_section_break = false
    end

    self:_schedule_follow()

    return self:_own_edit(function(bufnr)
        -- right_gravity so the mark rides past the region going in below it and
        -- the next record on this call reads back a row underneath, not above.
        tracker.trailing_insert_mark_id = vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_TOOL_BLOCKS,
            insert_row,
            0,
            { id = tracker.trailing_insert_mark_id, right_gravity = true }
        )

        vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, lines)
        -- Measured from the blank above the insert rather than the insert row:
        -- that blank closes the anchor block, and a prose run whose first chunk
        -- appended to it records it as the run's start. Left where it is, the
        -- run would read as beginning inside the region just put above it.
        self:_shift_prose_rows_below(insert_row - 1, #lines)

        self:_decorate_collapsed_region(
            bufnr,
            insert_row + body_offset,
            insert_row + body_offset + #body - 1,
            sign
        )
        return true
    end) == true
end

--- Render the thinking streamed since the last flush as one collapsed region
--- carrying the thinking glyph.
---
--- Thinking is buffered rather than streamed because the fence has to reach the
--- buffer in a single write. Held open across chunks, `_reflow_chunks` would
--- rewrite the rows it spans, and a `set_lines` over a row drops the signs on
--- it. Nothing shows meanwhile except the status indicator, which already says
--- "thinking".
---
--- Public because `SessionRestore.replay_messages` ends on this too — a stored
--- history whose last entry is a thought would otherwise stay buffered until
--- the next turn's first write and render under the new prompt.
function MessageWriter:flush_thought_run()
    local text = self._thought_run
    self._thought_run = nil
    if not text or vim.trim(text) == "" then
        return
    end

    self:_write_collapsed_region(
        TextWrap.wrap_prose(
            vim.split(vim.trim(text), "\n", { plain = true }),
            self:_get_wrap_width()
        ),
        Glyphs.THINKING_SIGN
    )
end

--- Render one hook's activity as a collapsed region carrying the hook glyph and
--- the name of the script it came from.
---
--- A region of its own rather than part of the tool call that triggered it: an
--- injection is a separate input the model received. It carries no heading for
--- the reason `queries/agentic/context.scm` documents — a titled heading over a
--- fenced body pins the treesitter-context breadcrumb.
---
--- Placed under the tool call the hook fired on when `tool_call_id` names one
--- still in the buffer, so the record reads under that call rather than under
--- whatever has been written since the hook ran — the transcript gives no
--- signal for when its records reach disk, so no drain trigger can place them
--- by buffer position alone. Appended at the end otherwise: a record from a
--- turn-boundary event names no call, and one whose block was never rendered
--- has nothing to sit under.
---
--- Not persisted: `ChatHistory` has no hook message variant yet, so a restored
--- session shows none of these. Missing work, not a rendering bug.
--- @param body string[] The hook's output, unwrapped
--- @param script string|nil Basename of the script it came from, if known
--- @param tool_call_id string|nil The call the hook fired on, if any
function MessageWriter:write_hook_block(body, script, tool_call_id)
    local wrapped = TextWrap.wrap_prose(body, self:_get_wrap_width())
    local sign = Glyphs.HOOK .. " "

    if
        tool_call_id
        and self:_insert_collapsed_region(wrapped, sign, script, tool_call_id)
    then
        return
    end

    -- Appending under a buffered thought run would put the region above the
    -- thinking it followed; an anchored one has no such ordering to keep.
    self:flush_thought_run()
    self:_write_collapsed_region(wrapped, sign, script)
end

--- The identity sign for a prompt heading row: the command's own glyph when the
--- prompt is a `/command`, the generic prompt marker otherwise.
---
--- A forwarded command reaches the buffer as a prompt like any other text, so
--- without this every one of them would read as "the user said something". The
--- word carries more than the marker does, and the same word gets the same
--- glyph whether the provider or `SessionManager` answers it — a local
--- command's notice takes its sign from the same table.
--- @param text string Raw prompt text
--- @return string sign
local function prompt_sign(text)
    local word = PromptBlocks.command(text)
    if not word then
        return Glyphs.PROMPT .. " "
    end
    return (Glyphs.COMMAND[word] or Glyphs.COMMAND_DEFAULT) .. " "
end

--- Write a user prompt to the chat buffer as a bracketed region: the heading
--- row takes an identity mark (which also drives `[[`/`]]` navigation), and a
--- multi-line prompt grows a `│`/`╰─` rail beneath it. Standalone rather than
--- delegating to write_message: it owns those signs and needs the heading row
--- post-append to place them.
--- @param text string Raw prompt text (first line becomes the `## ` heading)
--- @param extra_lines string[]|nil Display-only lines appended after the prompt
---        body (selected code / referenced files / diagnostics)
function MessageWriter:write_user_prompt(text, extra_lines)
    self:flush_thought_run()

    local lines = prompt_heading_lines(text)
    vim.list_extend(lines, extra_lines or {})

    local flat = vim.split(table.concat(lines, "\n"), "\n", { plain = true })
    -- An unclosed fence would swallow everything written after the prompt into
    -- the prompt's own code block.
    close_fence(flat)
    flat = TextWrap.wrap_prose(flat, self:_get_wrap_width())

    self:_schedule_follow()

    self:_own_edit(function(bufnr)
        -- End the prose run first. right_gravity=false survives appends but NOT
        -- a set_lines over the mark row, and prompt writes do not reset
        -- _chunk_start_line, so during replay (thought → prompt → thought) a
        -- later reflow range could span the heading and drag the marker.
        -- Mirrors the guard in write_tool_call_block.
        self:_end_prose_run(bufnr)

        self:_append_lines(flat)
        self:_append_lines({ "" })

        -- Compute the heading row AFTER the append: on an empty buffer
        -- _append_lines replaces row 0 rather than appending, so a pre-capture
        -- would be off by one (session/load replay clears the buffer before
        -- the first chunk). The -1 accounts for the trailing blank just added.
        local heading_row = vim.api.nvim_buf_line_count(bufnr) - #flat - 1

        -- The sign rides on the marker itself, so there is no separate scan.
        vim.api.nvim_buf_set_extmark(
            bufnr,
            MessageWriter.NS_USER_ACTIONS,
            heading_row,
            0,
            {
                right_gravity = false,
                sign_text = prompt_sign(text),
                sign_hl_group = Theme.HL_GROUPS.GLYPH_USER,
            }
        )

        render_region_rail(bufnr, heading_row, heading_row + #flat - 1)
    end)
end

--- @class agentic.ui.MessageWriter.Notice
--- @field glyph string Identity glyph for the command, stamped as the heading row's sign (see agentic.glyphs)
--- @field title string Heading text. Raw, not backtick-wrapped: an underscore or stray backtick in it can corrupt the heading through markdown inline parsing, the same exposure a user prompt's heading already carries.
--- @field body? string[] Already-formatted markdown lines placed under the heading
--- @field glyph_hl? string Highlight group for the sign; defaults to Theme's GLYPH_USER
--- @field mid_turn? boolean True when a turn is running. Decides whether the notice closes the turn — see write_notice.

--- Write the result of a locally-handled command as a glyph-signed heading.
---
--- A notice records something the *user* did, so its row carries an identity
--- sign in the same channel as a prompt's own and is navigable with `[[`/`]]`.
--- A notice with a body grows a `│`/`╰─` rail over those rows.
---
--- Always `##`. The heading level says whose row it is, not when it was written
--- (§ "Heading levels" in the `rendering` skill): a notice is a user action, a
--- sibling of the prompts, and `###` would file it among the running turn's
--- tool calls. Mid-turn that costs a breadcrumb — the notice closes the
--- `## prompt` section, so `queries/agentic/context.scm` pins the notice title
--- over the rest of the turn's prose (tool calls still pin their own `###`
--- head; innermost wins). Accepted: the title is the scope or model that just
--- changed, which is the more useful thing to see at that point anyway.
---
--- `mid_turn` decides only the turn boundary. Between turns the notice
--- finalizes; mid-turn it must NOT, since finalizing resets cross-turn state
--- the running turn still needs.
---
--- @param notice agentic.ui.MessageWriter.Notice
function MessageWriter:write_notice(notice)
    self:flush_thought_run()

    -- Never wrapped or truncated: an ATX heading has to stay on one row, and
    -- the title is the notice's whole record of the command — for `/trust` the
    -- part that would be cut is the scope path it exists to report. A title
    -- wider than the (nowrap) chat window runs past its edge and is reached by
    -- scrolling horizontally.
    local lines = { "## " .. notice.title }
    vim.list_extend(lines, notice.body or {})
    table.insert(lines, "")

    -- A notice ends the prose run it interrupts: without this the viewport
    -- stays anchored to the pre-notice prose, since the re-pin check only
    -- fires once the anchor is nil.
    self:_release_prose_pin()
    self:_schedule_follow()

    self:_own_edit(function(bufnr)
        -- End the prose run first, for the reason write_user_prompt documents:
        -- the heading would otherwise land inside an unclosed prose fence, and a
        -- later reflow's set_lines would span the heading row and drag the
        -- marker with it.
        self:_end_prose_run(bufnr)

        self:_append_lines(lines)

        -- Computed AFTER the append: on an empty buffer _append_lines replaces
        -- row 0 rather than appending, so a pre-capture would be off by one.
        local heading_row = vim.api.nvim_buf_line_count(bufnr) - #lines

        vim.api.nvim_buf_set_extmark(
            bufnr,
            MessageWriter.NS_USER_ACTIONS,
            heading_row,
            0,
            {
                right_gravity = false,
                sign_text = notice.glyph .. " ",
                sign_hl_group = notice.glyph_hl or Theme.HL_GROUPS.GLYPH_USER,
            }
        )

        render_region_rail(bufnr, heading_row, heading_row + #lines - 1)
    end)

    -- No section break to request: a `##` heading already closes whatever
    -- section it interrupts, so prose resuming after the notice needs no
    -- boundary line of its own.
    --
    -- Ends the turn directly rather than through
    -- `SessionManager:_finalize_turn`: a client-side notice dispatched nothing,
    -- so there is no usage to stamp and no hook activity to drain.
    if not notice.mid_turn then
        self:finalize_turn()
    end
end

--- Hints for known error classes. Keyed by both the Anthropic `error.type`
--- strings the embedded-JSON path produces and the internal classes the
--- errorKind map resolves to. authentication_error has no hint — re-auth is
--- handled by the caller (provider-specific re-auth flow).
--- @type table<string, string>
local error_hints = {
    overloaded_error = "The API is overloaded. Try again in a moment.",
    rate_limit_error = "Rate limited. Wait a moment before retrying.",
    billing_error = "Organisation spend limit reached — no automatic retry. "
        .. "Ask an admin to raise the cap, or run /usage-credits to request "
        .. "an increase.",
}

--- ACP bridge structured error kind → internal error class. The bridge attaches
--- `errorKind` to the JSON-RPC error `data` so clients classify without parsing
--- human-readable message text. Only kinds with confident recovery semantics are
--- mapped; unmapped kinds fall through to the text heuristics below.
--- @type table<string, string>
local error_kind_class = {
    authentication_failed = "authentication_error",
    oauth_org_not_allowed = "authentication_error",
    billing_error = "billing_error",
}

--- Strip the bridge's `Internal error: ` wrapper. It names the transport the
--- failure came back over, never the failure.
--- @param msg string
--- @return string stripped
local function strip_bridge_wrapper(msg)
    return (msg:gsub("^Internal error:%s*", ""))
end

--- Strip the bridge's wrapper and the `API Error: NNN` status behind it.
---
--- Only for a message whose class is already known, where a hint below says
--- what the status would have. On an unclassified message the status is the
--- one machine-readable fact in the line, and dropping it can leave nothing at
--- all: `API Error: 401` is entirely prefix.
--- @param msg string
--- @return string stripped
local function strip_error_prefix(msg)
    return (strip_bridge_wrapper(msg):gsub("^API Error:%s*%d+%s*", ""))
end

--- Parse a reset time like "5pm (Europe/London)" or "17:30 (Europe/London)"
--- into epoch seconds. Returns nil if parsing fails.
--- @param time_str string e.g. "5pm", "5:30pm", "17:00"
--- @param tz string e.g. "Europe/London"
--- @return number|nil epoch
local function parse_reset_time(time_str, tz)
    -- Use GNU date to parse the time in the given timezone
    local cmd =
        string.format("TZ=%s date -d 'today %s' +%%s 2>/dev/null", tz, time_str)
    local result = vim.fn.system(cmd)
    local epoch = tonumber(vim.trim(result))
    if not epoch then
        return nil
    end
    -- If the parsed time is in the past, it means tomorrow
    if epoch <= os.time() then
        epoch = epoch + 86400
    end
    return epoch
end

--- Format an ACP error into human-readable lines.
--- Classification prefers the bridge's structured `err.data.errorKind`; text
--- heuristics (embedded JSON, then usage-limit regex) supply the display lines
--- and the fallback class for errors/bridges that lack errorKind.
---
--- Example input message:
---   "Internal error: Failed to authenticate. API Error: 401\n
---    {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",
---    \"message\":\"Invalid authentication credentials\"}}"
--- Output: {"401 Invalid authentication credentials", "", "Try running /login ..."}
--- @param err agentic.acp.ACPError
--- @return string[] lines
--- @return string|nil error_type Error class (from errorKind if present, else text)
--- @return number|nil reset_epoch Epoch seconds when usage resets (for usage_limit errors)
local function format_error_lines(err)
    local lines = {}
    local msg = err.message or "Unknown error"

    -- The bridge attaches a structured errorKind to err.data; it is
    -- authoritative for classification because message wording is a display
    -- artefact that can change upstream and silently break text matching. The
    -- text paths below still build the display lines (richer when structured
    -- JSON or a reset clause is present) and supply the fallback class.
    local kind_class
    if type(err.data) == "table" then
        kind_class = error_kind_class[err.data.errorKind]
    end

    -- Try to extract embedded JSON from messages like:
    -- 'Internal error: API Error: 529\n{"type":"error","error":{"type":"overloaded_error","message":"Overloaded."}}'
    local json_str = msg:match("%b{}")
    if json_str then
        local ok, parsed = pcall(vim.json.decode, json_str)
        if ok and type(parsed) == "table" then
            local inner = parsed.error or parsed
            local error_type = inner.type or ""
            local error_msg = inner.message or ""

            -- Extract HTTP status code from prefix (e.g. "API Error: 401")
            local prefix = msg:sub(1, msg:find("{", 1, true) - 1)
            local http_code = prefix:match("(%d%d%d)%s*$")

            -- Build the main error line: "401 Invalid authentication credentials"
            -- or just the message if no HTTP code is available
            if http_code and error_msg ~= "" then
                table.insert(lines, http_code .. " " .. error_msg)
            elseif error_msg ~= "" then
                table.insert(lines, error_msg)
            elseif error_type ~= "" then
                local readable = error_type:gsub("_", " ")
                readable = readable:sub(1, 1):upper() .. readable:sub(2)
                table.insert(lines, readable)
            end

            -- Hint follows the resolved class (errorKind first) so a mapped
            -- kind that also carries embedded JSON keeps its class hint.
            local hint = error_hints[kind_class or error_type]
            if hint then
                table.insert(lines, "")
                table.insert(lines, hint)
            end

            local resolved_type = error_type ~= "" and error_type or nil
            return lines, kind_class or resolved_type
        end
    end

    -- errorKind classified with no richer structured JSON body (e.g. the
    -- billing spend cap): show the message with the wrapper prefix stripped,
    -- plus the class hint. Runs before the usage-limit scrape so a mapped kind
    -- is never reclassified as usage_limit or given a spurious reset epoch.
    if kind_class then
        vim.list_extend(
            lines,
            vim.split(strip_error_prefix(msg), "\n", { plain = true })
        )
        local hint = error_hints[kind_class]
        if hint then
            table.insert(lines, "")
            table.insert(lines, hint)
        end
        return lines, kind_class, nil
    end

    -- Unclassified from here down, so the message is all the reader gets: it
    -- keeps everything but the bridge's wrapper. The provider streams a fatal
    -- error as prose too, and the two copies have to match word for word for
    -- `drop_repeated_prose` to recognise the duplicate.
    msg = strip_bridge_wrapper(msg)

    -- Detect usage limit errors: "You're out of extra usage · resets 5pm (Europe/London)"
    local time_str, tz = msg:match("resets%s+(%d+:?%d*%s*[ap]m)%s+%(([%w/]+)%)")
    if not time_str then
        -- Try 24h format: "resets 17:00 (Europe/London)"
        time_str, tz = msg:match("resets%s+(%d+:%d+)%s+%(([%w/]+)%)")
    end
    if time_str then
        vim.list_extend(lines, vim.split(msg, "\n", { plain = true }))
        local reset_epoch = parse_reset_time(time_str, tz)
        return lines, "usage_limit", reset_epoch
    end

    vim.list_extend(lines, vim.split(msg, "\n", { plain = true }))
    return lines, nil
end

local HEADING = "## Error"
local HEADING_PREFIX_LEN = #"## "

--- The words of a string, one space between each.
--- @param text string
--- @return string
local function collapse_spaces(text)
    return vim.trim((text:gsub("%s+", " ")))
end

--- What the error says in its own words: the display lines up to the first
--- blank, which is where a class hint starts if the classifier added one.
--- @param lines string[] Formatted error lines
--- @return string
local function reported_text(lines)
    local said = {}
    for _, line in ipairs(lines) do
        if not line:match("%S") then
            break
        end
        said[#said + 1] = line
    end
    return table.concat(said, " ")
end

--- Delete the prose run's last paragraph when it says the same thing as `text`.
---
--- A fatal error reaches the chat twice: the provider streams it as assistant
--- prose, then returns it again as the prompt's JSON-RPC error. Only the second
--- copy carries the class and the reset time the plugin acts on, so the prose
--- copy is the one to drop — otherwise the reader sees the sentence, then sees
--- it again under `## Error`.
---
--- Matching is on words alone: the prose copy has been hard-wrapped to the
--- window by now and the error copy has not, so the two differ only in where
--- their line breaks fall. Only the run's *last* paragraph is a candidate, so a
--- duplicate spanning several paragraphs falls through and renders twice —
--- fail-safe, the direction that never eats prose the provider meant.
--- @param bufnr integer
--- @param run_start integer 0-indexed row the prose run began on
--- @param text string What the error is about to report
--- @return boolean removed
local function drop_repeated_prose(bufnr, run_start, text)
    local rows = vim.api.nvim_buf_get_lines(bufnr, run_start, -1, false)

    local last = #rows
    while last >= 1 and not rows[last]:match("%S") do
        last = last - 1
    end
    if last < 1 then
        return false
    end
    local first = last
    while first > 1 and rows[first - 1]:match("%S") do
        first = first - 1
    end

    local paragraph = table.concat(vim.list_slice(rows, first, last), " ")
    if collapse_spaces(paragraph) ~= collapse_spaces(text) then
        return false
    end

    -- The rows the run opened on — a blank, or the empty `###` that closed the
    -- section of the block above — introduce nothing once the only paragraph
    -- they led is gone, so they go with it.
    local leads_run = table
        .concat(vim.list_slice(rows, 1, first - 1), "")
        :match("^[#%s]*$") ~= nil
    vim.api.nvim_buf_set_lines(
        bufnr,
        run_start + (leads_run and 0 or first - 1),
        -1,
        false,
        {}
    )
    return true
end

--- Stamp ERROR_BODY over every non-blank row of an inclusive range.
--- @param bufnr integer
--- @param from_row integer 0-indexed first row
--- @param to_row integer 0-indexed last row, inclusive
local function highlight_error_body(bufnr, from_row, to_row)
    local rows = vim.api.nvim_buf_get_lines(bufnr, from_row, to_row + 1, false)
    for i, line in ipairs(rows) do
        if line ~= "" then
            vim.api.nvim_buf_set_extmark(bufnr, NS_ERROR, from_row + i - 1, 0, {
                end_col = #line,
                hl_group = Theme.HL_GROUPS.ERROR_BODY,
            })
        end
    end
end

--- Write an error message to the chat buffer as a signed, red-highlighted
--- region: `## Error` on the heading row under the error glyph, the provider's
--- own words wrapped beneath it, a `│`/`╰─` rail marking how far it reaches.
---
--- The `##` heading puts the error where it belongs in the section tree: a
--- turn-level report from the provider, a sibling of the prompt it answers, not
--- one of that turn's `###` tool calls. The identity sign stays out of
--- NS_USER_ACTIONS, unlike a prompt's or a notice's: `[[`/`]]` walks what the
--- user did, and an error is not that.
---
--- The block stays open — `write_error_action` extends it with whatever the
--- classification leads to (a countdown, a reauth offer), so the error and the
--- plugin's response to it read as one region.
--- @param err agentic.acp.ACPError
--- @return string|nil error_type Error class for caller to dispatch on (errorKind-first)
--- @return number|nil reset_epoch Epoch seconds when usage resets (for usage_limit errors)
function MessageWriter:write_error_message(err)
    self:flush_thought_run()

    local body_lines, error_type, reset_epoch = format_error_lines(err)
    local all_lines = { HEADING }
    vim.list_extend(
        all_lines,
        TextWrap.wrap_prose(body_lines, self:_get_wrap_width())
    )

    self:_release_prose_pin()
    self:_schedule_follow()

    self:_own_edit(function(bufnr)
        -- Before the run is bracketed, not after: `_end_prose_run` leaves the
        -- final bracket's marks untracked, and marks inside a deleted range
        -- collapse onto the deletion point instead of going with the text — a
        -- `╰─` stranded on the error's own heading row, with no id to free it.
        -- Every other mark that can fall in the range is tracked and freed by
        -- id, bar `_insert_collapsed_region`'s trailing insert mark, which no
        -- second sidecar arrives after a fatal error to resolve.
        local run_start = self._prose_run_start_line
        if
            run_start
            and drop_repeated_prose(bufnr, run_start, reported_text(body_lines))
        then
            self:_abandon_prose_run(bufnr)
        end

        -- An error ends the prose run. Without this the error block lands inside
        -- a fence the interrupted prose left open, and finalize_turn's reflow
        -- would later span it and move its NS_ERROR extmarks.
        self:_end_prose_run(bufnr)

        local was_empty = BufHelpers.is_buffer_empty(bufnr)
        self:_append_lines(all_lines)

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1
        local start_row = end_row - #all_lines + 1
        -- When the buffer was empty, _append_lines replaces instead of
        -- appending, so the heading is at row 0.
        if was_empty then
            start_row = 0
        end

        -- Highlight "Error" portion of "## Error" (after "## ")
        local heading_id = vim.api.nvim_buf_set_extmark(
            bufnr,
            NS_ERROR,
            start_row,
            HEADING_PREFIX_LEN,
            {
                end_col = #HEADING,
                hl_group = Theme.HL_GROUPS.ERROR_HEADING,
                priority = 200,
            }
        )
        highlight_error_body(bufnr, start_row + 1, end_row)

        vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_DECORATIONS,
            start_row,
            0,
            {
                sign_text = Glyphs.ERROR .. " ",
                sign_hl_group = Theme.HL_GROUPS.ERROR_HEADING,
            }
        )
        local rail_ids = render_region_rail(bufnr, start_row, end_row)

        self:_append_lines({ "" })

        self._error_block = {
            heading_id = heading_id,
            rail_ids = rail_ids,
            line_count = vim.api.nvim_buf_line_count(bufnr),
        }
    end)

    return error_type, reset_epoch
end

--- Grow the open error block down to the end of the buffer, re-stamping its rail
--- so the `╰─` sits on the row the block now ends on.
---
--- Re-stamped whole rather than repaired at the corner (the cadence
--- `_extend_prose_region` needs): an error block gains a row at a time, at most
--- a handful of times, so there is no streaming cost to amortise.
--- @param bufnr integer
--- @private
function MessageWriter:_extend_error_block(bufnr)
    local block = self._error_block
    if not block then
        return
    end
    local heading_row = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        NS_ERROR,
        block.heading_id,
        {}
    )[1]
    if not heading_row then
        self._error_block = nil
        return
    end

    Renderer.clear_decoration_extmarks(bufnr, block.rail_ids)
    block.rail_ids = render_region_rail(
        bufnr,
        heading_row,
        vim.api.nvim_buf_line_count(bufnr) - 1
    )
    block.line_count = vim.api.nvim_buf_line_count(bufnr)
end

--- Write a line in the error style, joined to the error region above it when it
--- directly follows one.
---
--- Two populations of caller. What an error led to — an auto-continue
--- countdown, a health check, a reauth offer — lands under the error that
--- prompted it and belongs in its region. Standalone plugin notices (a rejected
--- `/trust` scope, a truncated queue) reach the same styling with no error
--- above them, and get no region.
---
--- Which one it is comes from the buffer no longer ending where the block did,
--- rather than from a boundary call in every other writer: cheaper, and it
--- cannot be forgotten by the next writer added. It also closes the block
--- against a write that lands mid-turn, which a turn-boundary reset would miss.
--- @param text string The action hint text (e.g. "Press [r] to re-authenticate")
function MessageWriter:write_error_action(text)
    self:_schedule_follow()

    local lines = TextWrap.wrap_prose({ text }, self:_get_wrap_width())

    self:_own_edit(function(bufnr)
        local block = self._error_block
        if block and block.line_count ~= vim.api.nvim_buf_line_count(bufnr) then
            self._error_block = nil
        end

        self:_append_lines(lines)
        self:_append_lines({ "" })

        local end_row = vim.api.nvim_buf_line_count(bufnr) - 2
        highlight_error_body(bufnr, end_row - #lines + 1, end_row)

        self:_extend_error_block(bufnr)
    end)
end

--- Close out a turn: reset all per-turn state, end the prose run that closes
--- the turn, and append a trailing blank line.
function MessageWriter:finalize_turn()
    -- A turn ending mid-thought (a cancel, most often) still owes the reader
    -- the thinking it did. The flush ends the prose run before it, so a turn
    -- of prose → thinking closes with nothing left to bracket.
    self:flush_thought_run()

    -- Reset ALL per-turn state at the turn boundary. Any flag that was set
    -- during the turn must be cleared here, otherwise it silently corrupts
    -- subsequent turns (the "stuck 1 message behind" family of bugs).
    self._pending_section_break = false
    self:_release_prose_pin()
    self:_schedule_follow()

    self:_own_edit(function(bufnr)
        -- Before the trailing blank: that row carries the turn-usage footer and
        -- belongs to no region.
        self:_end_prose_run(bufnr)
        self:_append_lines({ "" })
    end)
end

--- Flush the buffered thought run and end the open prose run. Touches no
--- cross-turn state, so it is safe to call mid-turn.
function MessageWriter:end_runs()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end
    self:flush_thought_run()
    self:_release_prose_pin()
    self:_schedule_follow()
    self:_own_edit(function(bufnr)
        self:_end_prose_run(bufnr)
    end)
end

--- Append a `## <text>` heading that opens one subagent's section. Touches no
--- cross-turn state, so it is safe to call mid-turn.
--- @param text string
function MessageWriter:write_subagent_heading(text)
    self:flush_thought_run()
    -- The heading ends the prose run it interrupts, as a notice does.
    self:_release_prose_pin()
    self:_schedule_follow()
    self:_own_edit(function(bufnr)
        self:_end_prose_run(bufnr)
        self:_append_lines({ "## " .. text, "" })
    end)
end

--- Current rows of a tool call block, read from its range extmark.
--- @param block agentic.ui.MessageWriter.ToolCallBlock
--- @return integer|nil start_row header row, nil when the range extmark is absent or deleted
--- @return integer|nil end_row footer row
function MessageWriter:_block_rows(block)
    if not block.extmark_id then
        return nil, nil
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        Renderer.NS_TOOL_BLOCKS,
        block.extmark_id,
        { details = true }
    )
    local details = pos[3]
    if not pos[1] or not details or not details.end_row then
        return nil, nil
    end
    return pos[1], details.end_row
end

--- Stamp the per-turn token-usage footer on the trailing blank line that
--- `finalize_turn` just appended: dim, right-aligned virt_text like
--- `1.2k in · 0.4k out`. No-ops on missing or all-zero usage (stalls, cancels,
--- and silent upstream auth failures emit zeros — a "0" would mislead).
--- @param usage { inputTokens?: number, outputTokens?: number }|nil
function MessageWriter:set_turn_usage(usage)
    if type(usage) ~= "table" then
        return
    end
    local input = usage.inputTokens or 0
    local output = usage.outputTokens or 0
    if input == 0 and output == 0 then
        return
    end

    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end

    local text = string.format(
        "%s in · %s out",
        TextWrap.abbreviate_count(input),
        TextWrap.abbreviate_count(output)
    )
    local last_row = vim.api.nvim_buf_line_count(self.bufnr) - 1
    vim.api.nvim_buf_set_extmark(self.bufnr, NS_TURN_USAGE, last_row, 0, {
        virt_text = { { text, Theme.HL_GROUPS.TURN_USAGE } },
        virt_text_pos = "right_align",
    })
end

--- Reflow prose in the region written by write_message_chunk.
--- When `flush_all` is false (during streaming), only reflows complete
--- paragraphs — up to the last blank line, leaving the in-progress
--- paragraph untouched. When true (response finished), reflows everything.
---
--- `flush_all` is the end of the prose run, so it closes an unclosed fence — see
--- `close_fence` — and releases the run. Reached through `_end_prose_run`, its
--- only caller, which brackets the run the release drops.
--- The streaming path keeps `_chunk_start_line`
--- outside any open fence so that check sees the opener; a marker parked inside
--- a fence would also make `wrap_prose` hard-wrap code as prose, since it starts
--- each region assuming it is not in one.
--- @param bufnr integer
--- @param flush_all? boolean
function MessageWriter:_reflow_chunks(bufnr, flush_all)
    if flush_all then
        self._prose_run_start_line = nil
        self._prose_region_ids = nil
    end

    local start = self._chunk_start_line
    if not start then
        return
    end

    local buf_end = vim.api.nvim_buf_line_count(bufnr)
    if start >= buf_end then
        -- Nothing to reflow, but still clear the marker on flush so the
        -- next turn recalculates from scratch. Without this, the stale
        -- _chunk_start_line carries over and corrupts the next turn's reflow.
        if flush_all then
            self._chunk_start_line = nil
        end
        return
    end

    local reflow_end = buf_end -- 0-indexed exclusive

    if not flush_all then
        -- Find the last blank line in the range (excluding the final line
        -- which is still being appended to). Reflow up to and including it.
        local last_blank = nil
        local lines = vim.api.nvim_buf_get_lines(bufnr, start, buf_end, false)
        for i = #lines - 1, 1, -1 do -- skip last line (index #lines)
            if lines[i]:match("^%s*$") then
                last_blank = start + (i - 1) -- lines[1] = buffer line `start`
                break
            end
        end
        if not last_blank then
            return -- no complete paragraph yet
        end
        reflow_end = last_blank + 1 -- exclusive, include the blank line

        -- Stop short of an open fence: blank lines inside a code block would
        -- otherwise advance the marker into it.
        local _, opener = TextWrap.unclosed_fence(
            vim.list_slice(lines, 1, reflow_end - start)
        )
        if opener then
            reflow_end = start + opener - 1
            if reflow_end <= start then
                return
            end
        end
    end

    local raw = vim.api.nvim_buf_get_lines(bufnr, start, reflow_end, false)
    local wrapped = TextWrap.wrap_prose(raw, self:_get_wrap_width())

    if not vim.deep_equal(raw, wrapped) then
        vim.api.nvim_buf_set_lines(bufnr, start, reflow_end, false, wrapped)
        -- The replacement displaces the signs it spans, so the live region is
        -- rebuilt over the rewrapped rows. Not on the flush path, where
        -- `_end_prose_run` stamps the final bracket straight after.
        if not flush_all then
            self:_rebuild_prose_region(bufnr)
        end
    end

    if flush_all then
        -- Same job as `close_fence`, but appended to the buffer: reflow_end is
        -- the end of the buffer here, and extending `wrapped` would also extend
        -- `raw`, which wrap_prose returns unchanged when the window soft-wraps.
        local fence = TextWrap.unclosed_fence(wrapped)
        if fence then
            self:_append_lines({ fence })
        end
        self._chunk_start_line = nil
    else
        -- Advance past the reflowed region
        self._chunk_start_line = start + #wrapped
    end
end

--- Appends message chunks to the last line and column in the chat buffer
--- Some ACP providers stream chunks instead of full messages
--- @param update agentic.acp.SessionUpdateMessage
--- @param starts_response boolean|nil The chunk starts a new model response, which is separated by a blank line from prose it follows
function MessageWriter:write_message_chunk(update, starts_response)
    -- _on_session_update routes chunks to the writer for the agent that
    -- produced them (main → chat, subagent → its transcript), so each buffer
    -- shows its own agent's prose and thinking.
    local text = update.content
        and update.content.type == "text"
        and update.content.text --[[@as string]]

    if not text or text == "" then
        return
    end

    -- Thinking accumulates out of the buffer until the run ends; the answer
    -- that follows is what ends it, and has to be written after it.
    if update.sessionUpdate == "agent_thought_chunk" then
        self._thought_run = (self._thought_run or "") .. text
        return
    end
    self:flush_thought_run()

    -- Prose that resumes after a tool call must close its section so
    -- treesitter-context stops pinning the tool call's filename while the user
    -- reads the summary. Emit an empty `###` heading (no inline child, so
    -- context.scm never captures it) ahead of the prose, plus the blank line
    -- for visual breathing room. Once per prose run — the flag resets after
    -- the first chunk.
    if self._pending_section_break then
        text = "\n###\n\n" .. text
        self._pending_section_break = false
    end

    self:_schedule_follow()

    -- Read before the write, which opens a run at its first chunk. A run that
    -- opens on a blank row needs no break: the writer that ended the previous
    -- run (a tool call's section close, a thought region, a user prompt) left
    -- it. `end_runs` leaves the previous run's last row of text instead.
    local run_open = self._prose_run_start_line ~= nil

    self:_own_edit(function(bufnr)
        -- Rows rather than leading newlines, so the run starts on its text.
        if
            not run_open
            and not BufHelpers.is_buffer_empty(bufnr)
            and BufHelpers.trailing_blank_rows(bufnr, 1) == 0
        then
            self:_append_lines({ "", "" })
        end

        local last_line = vim.api.nvim_buf_line_count(bufnr) - 1

        if starts_response and run_open then
            text = TextWrap.paragraph_break(
                text,
                -- The last row is the open line, so its count of blank rows
                -- is the count of newlines ending the buffer.
                BufHelpers.trailing_blank_rows(bufnr, 2)
            )
        end

        -- Record where streamed content starts (0-indexed)
        if not self._chunk_start_line then
            local current = vim.api.nvim_buf_get_lines(
                bufnr,
                last_line,
                last_line + 1,
                false
            )[1] or ""
            -- If appending to a non-empty line, this line is the start
            -- If the line is empty, the new content starts here
            self._chunk_start_line = current == "" and last_line or last_line
            self._prose_run_start_line = self._chunk_start_line
        end

        local current_line = vim.api.nvim_buf_get_lines(
            bufnr,
            last_line,
            last_line + 1,
            false
        )[1] or ""
        local start_col = #current_line

        -- Fallback for response starts that `starts_response` cannot mark
        -- (chunks without a `messageId`). Guard against two messages being
        -- concatenated with no whitespace
        -- (e.g. auto-compaction text followed by resumed response). Normal
        -- streaming tokens include leading whitespace at word boundaries, so
        -- an uppercase letter directly after a lowercase letter, digit, or
        -- sentence-ending punctuation means the provider spliced two separate
        -- messages together. Uppercase after uppercase is left alone to avoid
        -- splitting abbreviations like "CWD" streamed as "C" + "WD".
        if
            start_col > 0
            and current_line:sub(-1):match("[%l%d%.%!%?%)\"']")
            and text:sub(1, 1):match("%u")
        then
            text = " " .. text
        end

        local lines_to_write = vim.split(text, "\n", { plain = true })

        local success, err = pcall(
            vim.api.nvim_buf_set_text,
            bufnr,
            last_line,
            start_col,
            last_line,
            start_col,
            lines_to_write
        )

        if not success then
            Logger.notify(
                "Failed to write message chunk:\n" .. tostring(err),
                vim.log.levels.ERROR,
                { title = "Agentic buffer write error" }
            )
        end

        -- Pin the start of the current prose run to the top of the viewport
        -- once its first text lands. The scan stops a few lines in: the run's
        -- opening rows are the only ones that can still be blank, and a pin set
        -- far below the run start would jump the viewport past prose the reader
        -- has not seen. Skip while every window is in user control — pinning
        -- means scrolling the view, which the user opted out of.
        if self._prose_anchor_line == nil and self:any_following() then
            local total = vim.api.nvim_buf_line_count(bufnr)
            self._prose_anchor_line = first_prose_row(
                bufnr,
                self._chunk_start_line,
                math.min(self._chunk_start_line + 4, total - 1)
            )
        end

        -- Wrap the last line immediately if it overflows, so the user sees
        -- wrapping during streaming instead of after the line completes.
        -- Skip when wrap_width is 0 (soft wrap enabled on the window).
        local wrap_width = self:_get_wrap_width()
        local end_line = vim.api.nvim_buf_line_count(bufnr) - 1
        local tail = vim.api.nvim_buf_get_lines(
            bufnr,
            end_line,
            end_line + 1,
            false
        )[1] or ""
        if wrap_width > 0 and #tail > wrap_width then
            local wrapped = TextWrap.wrap_single_line(tail, wrap_width)
            if #wrapped > 1 then
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    end_line,
                    end_line + 1,
                    false,
                    wrapped
                )
            end
        end

        -- Reflow complete paragraphs when a paragraph boundary was written
        if text:find("\n") then
            self:_reflow_chunks(bufnr)
        end

        -- Follow the rail down to the run's last drawn row, which any chunk can
        -- move: one carrying no newline still fills the blank row a paragraph
        -- break left behind, so a line-count check would miss it. A reflow that
        -- rewrote rows above has already rebuilt the region, leaving this a
        -- no-op.
        self:_extend_prose_region(bufnr)
    end)
end

--- @param lines string[]
--- @return nil
function MessageWriter:_append_lines(lines)
    local start_line = BufHelpers.is_buffer_empty(self.bufnr) and 0 or -1

    local success, err = pcall(
        vim.api.nvim_buf_set_lines,
        self.bufnr,
        start_line,
        -1,
        false,
        lines
    )

    if not success then
        Logger.notify(
            "Failed to append lines to buffer:\n" .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic buffer write error" }
        )
    end
end

--- Move each of `winids` that shows the buffer to its follow target, as an
--- `_own_change`: the held tool call's block (`hold_tool_call`), else the
--- prose pin (with `follow.pause_on_prose`), else the bottom. Scrolls down
--- only, except to place the held block. Each window records whether the pin
--- held it (`_pin_held`). Scrolls windows in user control too. A no-op with
--- `follow.enabled` off.
---
--- A held block not yet written stays unplaced, and the window takes the pin
--- or bottom.
--- @param winids integer[]
function MessageWriter:_scroll(winids)
    if Config.follow and Config.follow.enabled == false then
        -- The pin holds no window it does not scroll.
        for _, winid in ipairs(winids) do
            self._pin_held[winid] = nil
        end
        return
    end
    local held = self._held_tool_call_id
        and self.tool_call_blocks[self._held_tool_call_id]
    local held_start, held_end
    if held then
        held_start, held_end = self:_block_rows(held)
    end
    -- topline is 1-indexed; _prose_anchor_line is 0-indexed.
    local pause = Config.follow and Config.follow.pause_on_prose ~= false
    local max_topline = (pause and self._prose_anchor_line)
            and (self._prose_anchor_line + 1)
        or nil
    local padding = (Config.follow and Config.follow.bottom_padding) or 0

    local placed = false
    self:_own_change(function()
        for _, winid in ipairs(winids) do
            if
                vim.api.nvim_win_is_valid(winid)
                and vim.api.nvim_win_get_buf(winid) == self.bufnr
            then
                if self._newly_shown[winid] then
                    self._newly_shown[winid] = nil
                    vim.api.nvim_win_call(winid, function()
                        vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
                    end)
                end
                if not held_start then
                    self._pin_held[winid] = BufHelpers.scroll_down(
                        winid,
                        padding,
                        max_topline
                    ) or nil
                elseif self._hold_unplaced then
                    BufHelpers.show_rows(winid, padding, held_start, held_end)
                    placed = true
                    self._pin_held[winid] = nil
                else
                    BufHelpers.scroll_down(winid, padding, held_start + 1)
                    self._pin_held[winid] = nil
                end
            end
        end
    end)
    -- Left unplaced while no window took it, for the next one that follows,
    -- and while fold ops wait (insert mode): placed against folds still open,
    -- the block is placed again once they close.
    if placed and #self._pending_fold_ops == 0 then
        self._hold_unplaced = false
    end
end

--- If a write owes a scroll, scroll every window showing the buffer that is
--- not in user control.
function MessageWriter:_scroll_followers()
    if not self._scroll_owed then
        return
    end
    local winids = {}
    for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
        if not self._user_controlled[winid] then
            table.insert(winids, winid)
        end
    end
    self:_scroll(winids)
end

--- Owe a scroll for a write and schedule it after the current synchronous
--- write. It goes to the windows not in user control when it runs. Coalesces
--- the calls of one tick into one scroll.
---
--- When the write queued a fold op, the scroll is owned by
--- `flush_pending_fold_ops` instead: that runs strictly after treesitter's
--- fold-level recompute, so it measures the already-*closed* fold. Scrolling
--- here would race the recompute and park the viewport at the unfolded bottom
--- (the fold-vs-follow timing bug). The callback skips when fold ops are
--- pending, leaving the owed scroll for flush — unless they are held for
--- insert mode, a wait no write can afford to sit out.
function MessageWriter:_schedule_follow()
    self._scroll_owed = true

    if self._scroll_callback_queued then
        return
    end
    self._scroll_callback_queued = true

    vim.schedule(function()
        self._scroll_callback_queued = false

        -- Fold-close owns the scroll on this tick — leave it owed.
        -- Except while the ops are held for insert mode: that hold lasts as
        -- long as the user keeps typing, and deferring to a flush that will not
        -- run until then freezes the viewport for every write in between.
        if #self._pending_fold_ops > 0 and not self._fold_retry_armed then
            return
        end

        if vim.api.nvim_buf_is_valid(self.bufnr) then
            self:_scroll_followers()
        end

        self._scroll_owed = false
    end)
end

--- Queue an open/close of the treesitter fold containing `anchor_row`.
--- `anchor_row` is the first body line of a `*-fold`/`-difffold` block — a
--- level-1 row that belongs only to our fold (the fold spans
--- `code_fence_content`, so the concealed fence delimiters are level 0,
--- outside it). The one-level :foldopen/:foldclose hits exactly our block,
--- leaving other blocks untouched. Anchoring on a body line (not the
--- delimiter) also keeps a closed fold's first screen row visible, so the
--- `··· N lines ···` foldtext shows.
---
--- An anchor extmark tracks the row across later edits, and the op is deferred
--- so it can wait for a chat window: with none visible the anchor stays pending
--- until BufWinEnter.
--- @param anchor_row integer 0-indexed buffer row of the block's first body line
--- @param open boolean Desired state — true opens the fold, false closes it
function MessageWriter:_queue_fold(anchor_row, open)
    self:_queue_fold_op(self:_place_fold_anchor(anchor_row), open)
end

--- Place a fold anchor: an extmark in NS_FOLD_ANCHORS that tracks `row`
--- across later edits.
--- @param row integer 0-indexed buffer row
--- @return integer id Extmark id
function MessageWriter:_place_fold_anchor(row)
    return vim.api.nvim_buf_set_extmark(self.bufnr, NS_FOLD_ANCHORS, row, 0, {})
end

--- Queue an open or close of the fold at an anchor extmark, and schedule a
--- flush of the queue.
--- @param id integer Anchor extmark id in NS_FOLD_ANCHORS
--- @param open boolean True opens the fold, false closes it
function MessageWriter:_queue_fold_op(id, open)
    table.insert(self._pending_fold_ops, { id = id, open = open })
    vim.schedule(function()
        self:flush_pending_fold_ops()
    end)
end

--- Forget a tool call block's fold: delete its anchor extmark and the fold
--- state recorded for it, and clear the block's fold fields.
--- @param block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:_drop_block_fold(block)
    if block.fold_anchor_id then
        vim.api.nvim_buf_del_extmark(
            self.bufnr,
            NS_FOLD_ANCHORS,
            block.fold_anchor_id
        )
        self._fold_states[block.fold_anchor_id] = nil
    end
    block.fold_anchor_id = nil
    block.fold_open = nil
    block.fold_sent = nil
end

--- Place a rendered tool call block's fold anchor, and queue its fold state
--- if the state is due at the block's status. Sets the block's fold fields.
--- `fold_sent` stays nil while the state is not due. Each re-render sends a
--- due state again, which replaces a fold change the user made by hand.
--- @param block agentic.ui.MessageWriter.ToolCallBlock
--- @param start_row integer 0-indexed first row of the block
--- @param fold_anchor integer|nil Offset from `start_row` of the first body row of the block's foldable fence. Nil when it has none.
--- @param fold_state agentic.ui.FoldState|nil Fold state of the block's fence. Nil when it has none.
function MessageWriter:_render_block_fold(
    block,
    start_row,
    fold_anchor,
    fold_state
)
    if not fold_anchor then
        return
    end
    block.fold_anchor_id = self:_place_fold_anchor(start_row + fold_anchor)
    block.fold_open = fold_state == "open"
    if
        fold_state ~= "closed_when_final" or is_final_status(block.status)
    then
        self:_queue_fold_op(block.fold_anchor_id, block.fold_open)
        block.fold_sent = block.fold_open
    end
end

--- Queue `open` for a tool call block's fold and record it as sent. No-op
--- when the block has no fold anchor or `open` is the state last sent, so a
--- repeated call does not undo a fold the user changed by hand.
--- @param block agentic.ui.MessageWriter.ToolCallBlock
--- @param open boolean True opens the fold, false closes it
function MessageWriter:_settle_block_fold(block, open)
    if block.fold_anchor_id and open ~= block.fold_sent then
        self:_queue_fold_op(block.fold_anchor_id, open)
        block.fold_sent = open
        block.fold_open = open
    end
end

--- Open or close the fold containing `row` in `winid`.
--- @param winid integer
--- @param row integer 0-indexed
--- @param open boolean
local function apply_fold(winid, row, open)
    -- A missing fold (E490) is non-fatal: the body just stays visible, so it
    -- is swallowed deliberately.
    pcall(vim.api.nvim_win_call, winid, function()
        vim.cmd(
            string.format("%d%s", row + 1, open and "foldopen" or "foldclose")
        )
    end)
end

--- See _queue_fold.
--- @param anchor_row integer
function MessageWriter:_close_fold(anchor_row)
    self:_queue_fold(anchor_row, false)
end

--- Hold the pending fold ops until the user leaves insert mode, then retry.
---
--- Vim suppresses foldUpdate in insert mode, so a `:foldclose` issued while the
--- user types in the prompt buffer finds no fold and raises E490 — and since
--- the flush drops each op after trying it, the body would stay expanded for
--- good. That is the dominant case for a thought run, which finishes precisely
--- while the user is typing the next prompt. The autocmd is not buffer-scoped:
--- the insert session it waits on is in another buffer.
--- @private
function MessageWriter:_retry_folds_on_insert_leave()
    if self._fold_retry_armed then
        return
    end
    self._fold_retry_armed = true
    vim.api.nvim_create_autocmd("InsertLeave", {
        once = true,
        callback = function()
            self._fold_retry_armed = false
            -- Scheduled so the fold levels vim recomputes on leaving insert
            -- are in place before :foldclose looks for one.
            vim.schedule(function()
                self:flush_pending_fold_ops()
            end)
        end,
    })
end

--- Give every applied fold its recorded state in `winid`. Fold state is
--- window-local, so a window opened later would otherwise show every block
--- open. Forgets the states whose anchor extmark is gone.
--- @param winid integer
function MessageWriter:replay_folds(winid)
    self:_own_change(function()
        for id, open in pairs(self._fold_states) do
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                self.bufnr,
                NS_FOLD_ANCHORS,
                id,
                {}
            )
            if pos[1] then
                apply_fold(winid, pos[1], open)
            else
                self._fold_states[id] = nil
            end
        end
    end)
end

--- Apply every pending fold op (see _queue_fold). Resolves each anchor
--- extmark's current row so edits since the render are accounted for. No-op
--- when nothing is pending. When no chat window exists yet, or the user is in
--- insert mode, the anchors stay pending and a retry is armed (BufWinEnter and
--- InsertLeave respectively).
--- Then scrolls the windows that follow, if a write owes a scroll.
--- Public so the BufWinEnter autocmd closure can reach it without tripping
--- LuaLS's invisible-field check.
function MessageWriter:flush_pending_fold_ops()
    if #self._pending_fold_ops == 0 then
        return
    end
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        self._pending_fold_ops = {}
        return
    end
    local winids = vim.fn.win_findbuf(self.bufnr)
    if #winids == 0 then
        return
    end
    if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
        self:_retry_folds_on_insert_leave()
        -- Scroll for the owed write before returning. `_schedule_follow`'s
        -- callback skips for as long as ops are pending, on the assumption that
        -- flush follows within the tick; holding for a whole insert session
        -- would instead freeze the viewport for every write until the user
        -- leaves insert. Scroll against the still-open fold and leave the
        -- scroll owed, so the InsertLeave retry re-measures the collapsed
        -- height.
        self:_scroll_followers()
        return
    end

    -- An own change: collapsing or expanding a fold shifts the view.
    self:_own_change(function()
        for _, op in ipairs(self._pending_fold_ops) do
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                self.bufnr,
                NS_FOLD_ANCHORS,
                op.id,
                {}
            )
            if pos[1] then
                for _, winid in ipairs(winids) do
                    apply_fold(winid, pos[1], op.open)
                end
                self._fold_states[op.id] = op.open
            end
        end
    end)
    self._pending_fold_ops = {}

    -- The fold path's single scroll. The folds are now closed, so the
    -- fold-aware scroll_down measures the collapsed height — `_schedule_follow`'s
    -- callback skipped while these ops were pending and deferred to here.
    self:_scroll_followers()
    self._scroll_owed = false
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBlock
function MessageWriter:write_tool_call_block(tool_call_block)
    -- Thinking interrupted by a tool call belongs above it.
    self:flush_thought_run()

    -- A tool call ends the current prose run, and with it the prose pin.
    self:_release_prose_pin()

    -- Mode-switch tool calls (EnterPlanMode, ExitPlanMode, EnterWorktree)
    -- carry internal instructions in their body — strip it so only the
    -- compact header renders (e.g. "Switch Mode `EnterPlanMode`").
    -- TodoWrite body is the raw JSON request — hide it since the todo window
    -- shows the rendered todos.
    if
        AcpKind.normalise(tool_call_block.kind) == "switch_mode"
        or AcpKind.normalise(tool_call_block.kind) == "todowrite"
    then
        tool_call_block.body = nil
    end

    self:_schedule_follow()

    self:_own_edit(function(bufnr)
        -- End the prose run before writing the tool call block. Without this,
        -- finalize_turn's reflow would later process a range that includes these
        -- tool call lines, destroying extmarks (decorations, status, range
        -- tracking) via nvim_buf_set_lines.
        self:_end_prose_run(bufnr)

        local kind = tool_call_block.kind

        local lines, highlight_ranges, ansi_highlights, fold_anchor, dim_range, fold_state =
            Renderer.prepare_block_lines(
                tool_call_block,
                self:_get_wrap_width()
            )

        self:_append_lines(lines)

        -- Compute start/end AFTER _append_lines: when the buffer was empty,
        -- _append_lines replaces instead of appending, so line_count before
        -- the call would over-count by 1.
        local end_row = vim.api.nvim_buf_line_count(bufnr) - 1
        local start_row = end_row - #lines + 1

        Renderer.apply_block_highlights(
            bufnr,
            start_row,
            end_row,
            kind,
            highlight_ranges,
            ansi_highlights,
            tool_call_block.search_matches,
            tool_call_block.search_ansi
        )

        tool_call_block.decoration_extmark_ids = Renderer.render_decorations(
            bufnr,
            start_row,
            end_row,
            kind
        )

        self:_render_block_fold(
            tool_call_block,
            start_row,
            fold_anchor,
            fold_state
        )
        if dim_range then
            local dim_id = Renderer.set_dim_range(
                bufnr,
                start_row + dim_range[1],
                start_row + dim_range[2]
            )
            table.insert(tool_call_block.decoration_extmark_ids, dim_id)
        end

        -- right_gravity=true so the start moves past content inserted
        -- at the boundary by a preceding block's update_tool_call_block.
        -- set_lines(buf, prev_start, prev_end+1) has its exclusive end
        -- at this block's start row — right_gravity=false would pull the
        -- start into the replacement range, corrupting this extmark.
        tool_call_block.extmark_id = vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_TOOL_BLOCKS,
            start_row,
            0,
            {
                end_row = end_row,
                right_gravity = true,
                end_right_gravity = false,
            }
        )

        self.tool_call_blocks[tool_call_block.tool_call_id] = tool_call_block

        Renderer.apply_status_footer(bufnr, end_row, tool_call_block.status)

        materialize_injections(bufnr, start_row, end_row)

        self:_append_lines({ "" })
        self:_mark_section_break()
    end)
end

--- Ids of the tracked tool call blocks whose status can still change.
---
--- A collected list, not a live iterator: a caller stamping each id resizes the
--- buffer, and `update_tool_call_block` drops a tracker outright when its range
--- extmark has collapsed — both mutate `tool_call_blocks` mid-walk.
--- @return string[] tool_call_ids
function MessageWriter:nonfinal_tool_call_ids()
    local ids = {}
    for id, block in pairs(self.tool_call_blocks) do
        if not is_final_status(block.status) then
            table.insert(ids, id)
        end
    end
    return ids
end

--- Follow a prose row across a tool call block's resize, so a row recorded
--- before the edit still points at the content it was recorded for. A row that
--- fell inside the old block range comes back just past the new one: nothing
--- tracking prose may point into block lines, where a reflow's `set_lines` would
--- destroy the block's extmarks.
--- @param row integer|nil
--- @param start_row integer 0-indexed first row of the block
--- @param old_end_row integer 0-indexed last row of the block before the edit
--- @param new_end_row integer 0-indexed last row of the block after the edit
--- @return integer|nil
local function shift_across_block(row, start_row, old_end_row, new_end_row)
    if not row or row <= start_row then
        return row
    end
    if row > old_end_row then
        return row + (new_end_row - old_end_row)
    end
    return new_end_row + 1
end

--- @param tool_call_block agentic.ui.MessageWriter.ToolCallBase
function MessageWriter:update_tool_call_block(tool_call_block)
    local tracker = self.tool_call_blocks[tool_call_block.tool_call_id]

    if not tracker then
        Logger.notify(
            "Tool call update for unknown block: "
                .. tostring(tool_call_block.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: missing tracker" }
        )
        return
    end

    -- Strip internal instructions from switch_mode updates
    -- TodoWrite body is the raw JSON request — hide it since the todo window
    -- shows the rendered todos.
    if
        AcpKind.normalise(tracker.kind) == "switch_mode"
        or AcpKind.normalise(tracker.kind) == "todowrite"
    then
        tool_call_block.body = nil
    end

    -- For read blocks, extract range from the current argument before the merge
    -- overwrites it — the initial title may contain "(N - M)" that the adapter
    -- update replaces with just the file path.
    if AcpKind.normalise(tracker.kind) == "read" and not tracker.read_range then
        local _, range = Renderer.parse_read_range(tracker.argument)
        if range then
            tracker.read_range = range
        end
    end

    -- Some ACP providers don't send the diff on the first tool_call
    local already_has_diff = tracker.diff ~= nil
    local previous_body = tracker.body

    tracker = vim.tbl_deep_extend("force", tracker, tool_call_block)

    -- Merge body: append new to previous with divider if both exist and are different
    if
        previous_body
        and tool_call_block.body
        and not vim.deep_equal(previous_body, tool_call_block.body)
    then
        local merged = vim.list_extend({}, previous_body)
        vim.list_extend(merged, { "", "---", "" })
        vim.list_extend(merged, tool_call_block.body)
        tracker.body = merged
    end

    self.tool_call_blocks[tool_call_block.tool_call_id] = tracker

    local pos = vim.api.nvim_buf_get_extmark_by_id(
        self.bufnr,
        Renderer.NS_TOOL_BLOCKS,
        tracker.extmark_id,
        { details = true }
    )

    if not pos or not pos[1] then
        Logger.notify(
            "Tool call extmark lost: " .. tostring(tracker.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: extmark lost" }
        )
        return
    end

    local start_row = pos[1]
    local details = pos[3]
    local old_end_row = details and details.end_row

    if not old_end_row then
        Logger.notify(
            "Tool call extmark has no end_row: "
                .. tostring(tracker.tool_call_id),
            vim.log.levels.WARN,
            { title = "Agentic sync: extmark corrupt" }
        )
        return
    end

    if start_row >= old_end_row then
        Logger.debug_to_file(
            "COLLAPSED EXTMARK — tool call block range is degenerate, bailing out",
            {
                tool_call_id = tracker.tool_call_id,
                kind = tracker.kind,
                argument = tracker.argument,
                start_row = start_row,
                old_end_row = old_end_row,
                status = tool_call_block.status,
                already_has_diff = already_has_diff,
                line_count = vim.api.nvim_buf_line_count(self.bufnr),
            }
        )
        -- Remove from tracking — the block is corrupt and cannot be updated
        if tracker.trailing_insert_mark_id then
            vim.api.nvim_buf_del_extmark(
                self.bufnr,
                Renderer.NS_TOOL_BLOCKS,
                tracker.trailing_insert_mark_id
            )
        end
        self.tool_call_blocks[tool_call_block.tool_call_id] = nil
        return
    end

    self:_schedule_follow()

    self:_own_edit(function(bufnr)
        -- Diff blocks don't change after the initial render
        -- only update status highlights - don't replace content.
        -- Exception: the transition to `failed` re-renders so the failure
        -- reason renders below the diff and the diff folds closed
        -- (tool_call_renderer diff branch). Re-extraction is safe — a failed
        -- file-mutating tool never applied its change, so the file is
        -- unchanged and reproduces the same diff.
        if already_has_diff and tracker.status ~= "failed" then
            if old_end_row > vim.api.nvim_buf_line_count(bufnr) then
                Logger.notify(
                    string.format(
                        "Tool call footer out of bounds: row %d, buf has %d lines",
                        old_end_row,
                        vim.api.nvim_buf_line_count(bufnr)
                    ),
                    vim.log.levels.WARN,
                    { title = "Agentic sync: footer OOB" }
                )
                return false
            end

            -- Decorations (kind glyph, │, ╰─) are stable — leave them in place.
            -- Only refresh status footer which changes on completion.
            Renderer.apply_status_footer(bufnr, old_end_row, tracker.status)
            -- A non-failed diff's fold state does not depend on the status,
            -- so the state stored at render still holds.
            if is_final_status(tracker.status) then
                self:_settle_block_fold(tracker, tracker.fold_open == true)
            end

            return false
        end

        local new_lines, highlight_ranges, ansi_highlights, fold_anchor, dim_range, fold_state =
            Renderer.prepare_block_lines(tracker, self:_get_wrap_width())

        -- Compare content lines excluding the footer — the buffer's footer
        -- has status text while prepare_block_lines produces "" for it.
        local current_lines =
            vim.api.nvim_buf_get_lines(bufnr, start_row, old_end_row + 1, false)
        local content_unchanged = #new_lines == #current_lines
        if content_unchanged then
            for i = 1, #new_lines - 1 do
                if new_lines[i] ~= current_lines[i] then
                    content_unchanged = false
                    break
                end
            end
        end

        if content_unchanged then
            Renderer.apply_status_footer(bufnr, old_end_row, tracker.status)
            if is_final_status(tracker.status) then
                self:_settle_block_fold(tracker, fold_state == "open")
            end
            return false
        end

        Renderer.clear_decoration_extmarks(
            bufnr,
            tracker.decoration_extmark_ids
        )
        Renderer.clear_status_namespace(bufnr, start_row, old_end_row)

        -- Clear diff highlights BEFORE set_lines. `line_hl_group` (DIFF_ADD/
        -- DIFF_DELETE) extmarks migrate to the edge of the replaced range when
        -- set_lines runs — to EOF when the block is the last thing in the
        -- buffer. A clear afterwards using the pre-edit range then misses the
        -- migrated marks, leaving an orphaned diff-bg highlight on a line
        -- outside the block. The re-render only runs for diffs on the failed
        -- transition, which is why this only bit failed edits.
        pcall(
            vim.api.nvim_buf_clear_namespace,
            bufnr,
            Renderer.NS_DIFF_HIGHLIGHTS,
            start_row,
            old_end_row + 1
        )

        self:_drop_block_fold(tracker)

        vim.api.nvim_buf_set_lines(
            bufnr,
            start_row,
            old_end_row + 1,
            false,
            new_lines
        )

        local new_end_row = start_row + #new_lines - 1

        -- Follow the rows that track the live prose run across the line count
        -- change (e.g. diff data arriving late), so that _reflow_chunks does not
        -- process tool call block lines and the run is still bracketed from its
        -- own first row. The region's own signs need no help: extmarks move with
        -- the lines below a replacement.
        local line_delta = new_end_row - old_end_row
        if line_delta ~= 0 then
            self._chunk_start_line = shift_across_block(
                self._chunk_start_line,
                start_row,
                old_end_row,
                new_end_row
            )
            self._prose_run_start_line = shift_across_block(
                self._prose_run_start_line,
                start_row,
                old_end_row,
                new_end_row
            )
        end

        -- Same shift for the prose run anchor: prose is written after the
        -- most recent tool call, but updates can resize *older* blocks above
        -- it. The anchor must move with the lines it points to so the pin
        -- stays on the same content. Not `shift_across_block`: a row swallowed
        -- by the block releases the pin rather than relocating, since a pin is
        -- a viewport promise about specific content and there is no equivalent
        -- of "just past the block" that keeps it.
        if line_delta ~= 0 and self._prose_anchor_line then
            if self._prose_anchor_line > old_end_row then
                self._prose_anchor_line = self._prose_anchor_line + line_delta
            elseif self._prose_anchor_line >= start_row then
                -- Block ate the anchor line (shouldn't happen for prose
                -- written after this block, but bail out safely).
                self:_clear_prose_pin()
            end
        end

        -- Rows are read when the callback runs, since lines written above
        -- the block in the meantime move it down. A later update replaces
        -- this pass's lines.
        local pass = (tracker.highlight_pass or 0) + 1
        tracker.highlight_pass = pass
        local tool_call_id = tracker.tool_call_id
        vim.schedule(function()
            local current = self.tool_call_blocks[tool_call_id]
            if
                not current
                or current.highlight_pass ~= pass
                or not vim.api.nvim_buf_is_valid(bufnr)
            then
                return
            end
            local block_start, block_end = self:_block_rows(current)
            if block_start then
                Renderer.apply_block_highlights(
                    bufnr,
                    block_start,
                    block_end,
                    current.kind,
                    highlight_ranges,
                    ansi_highlights,
                    current.search_matches,
                    current.search_ansi
                )
            end
        end)

        vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_TOOL_BLOCKS,
            start_row,
            0,
            {
                id = tracker.extmark_id,
                end_row = new_end_row,
                right_gravity = true,
                end_right_gravity = false,
            }
        )

        tracker.decoration_extmark_ids = Renderer.render_decorations(
            bufnr,
            start_row,
            new_end_row,
            tracker.kind
        )

        self:_render_block_fold(tracker, start_row, fold_anchor, fold_state)
        if dim_range then
            local dim_id = Renderer.set_dim_range(
                bufnr,
                start_row + dim_range[1],
                start_row + dim_range[2]
            )
            table.insert(tracker.decoration_extmark_ids, dim_id)
        end

        Renderer.apply_status_footer(bufnr, new_end_row, tracker.status)

        materialize_injections(bufnr, start_row, new_end_row)
    end)
end

--- @private
--- @param err agentic.acp.ACPError
--- @return string[] lines
--- @return string|nil error_type
--- @return number|nil reset_epoch
function MessageWriter._format_error_lines(err)
    return format_error_lines(err)
end

--- @private
--- @param time_str string
--- @param tz string
--- @return number|nil epoch
function MessageWriter._parse_reset_time(time_str, tz)
    return parse_reset_time(time_str, tz)
end

return MessageWriter
