# Plan: questions to the user as a tool with a panel
Status: draft
Priority: P3
Depends:

## Relevant files
- `pi/agentic.ts` — the plugin's pi extension; registers the tool
- `lua/agentic/pi/` — `pi_tool_calls.lua` (tool call → block)
- `lua/agentic/ui/agents_panel.lua` — a panel with per-row actions (`Actions`) and `dd` as an operator; prior art for the panel
- `lua/agentic/ui/todo_list.lua` — prior art for a panel that opens with entries and closes when empty
- `lua/agentic/ui/chat_widget.lua` — `jump_prompt`, `_setup_keymaps`
- `lua/agentic/completion/lsp_server.lua` — `/` and `@` completion
- `lua/agentic/utils/prompt_blocks.lua`, `lua/agentic/session_manager.lua` (`_drain_queue`) — prompt dispatch and the queue
- `.claude/rules/session-isolation.md` — per-session store and panel buffer
- `lua/agentic/ui/tool_call_layout.lua`, `tool_call_renderer.lua` — tool call blocks
- `queries/agentic/*.scm` — the markdown parse of the chat
- `lua/agentic/config_default.lua` — `keymaps.agent`
- Claude Code source, `src/tools/AskUserQuestionTool/` (`AskUserQuestionTool.tsx`, `prompt.ts`), `src/utils/attachments.ts` (`TODO_REMINDER_CONFIG`, `todo_reminder`), `src/utils/messages.ts` (`todo_reminder`, `task_reminder` text)
- Skills: `rendering`, `follow`, `provider-system`

## Background
When the user does not answer a question, the agent asks it again in later
replies, often shorter each time, or writes "see above". The user must
then search the chat for the full question.

The plugin can give each question a number and keep the list. The agent
asks through a tool, and the tool result returns the number the plugin
assigned (`Recorded as Q7`). The agent never counts or numbers questions
itself. The open questions show in a panel.

Alternatives that were rejected:
- Turn counts in prose ("3 prompts ago"), with `3[[` to jump back: models count
  badly, and compaction, queued prompt blocks and synthetic prompts change
  the count.
- Question numbers that the agent assigns: the counter exists only in the
  model's context and restarts or collides after compaction.
- A questions file that the agent edits: the plugin must parse free-form
  text, the agent needs write permission, and a stop hook would have to
  guess what is a question.
- The same tool over ACP: Claude Code takes a custom tool only through an
  MCP server (`session/new` `mcpServers`). `REFACTOR-pi-only.md` removes
  that path, so the work is not done twice. Until that plan lands, ACP
  chats do not get the tool.

The existing pi ask packages are modal copies of
`AskUserQuestion`: the turn stops until the user answers in a form. Most
draw a terminal UI, which an RPC client cannot show. None keeps a list of
open questions while the agent continues.

## Changes
A sketch. The open questions below decide the details.

1. `pi/agentic.ts` registers a tool, for example `ask`. It does not block:
   it records the question and returns `Recorded as Q<n>` at once. Actions:
   ask, resolve, list.
2. The plugin keeps one store of questions per session and saves it with the
   chat JSON. Each entry has a number, the input, a status, and the chat
   position of its block.
3. The chat shows a small block at the place where the agent asked, so the
   question is read in context. The panel lists the open questions. It
   opens with the first open question and closes when none are left.
4. `Q<n>` in prose is highlighted only when `Q<n>` is in the store, and
   `gd` on it goes to the block.
5. Panel and chat keymaps on an entry: answer, dismiss (`dd`), ask the agent
   to rephrase (`cc`). Each sends a fixed message to the agent, for example
   "User dismissed Q3; do not ask it again".
6. Input buffer completion lists the open questions, with the full question
   in the documentation float.
7. After compaction the extension supplies the list of open questions again.
8. Detection of questions in prose: a tree-sitter query on the reply finds
   sentences that end in `?` and skips code spans, fenced code and block
   quotes. A hit gives one reminder per session ("use the ask tool").
   Misses are acceptable.
9. The guidance on when to use the tool is in the tool description, not in
   `AGENTS.md`, because only agentic.nvim has the tool.

## Expected outcome
- The agent asks through the tool; each question has one number, assigned
  by the plugin.
- Open questions are in a panel. The agent does not repeat them.
- The user goes from `Q<n>` to its block with `gd`, and answers, dismisses
  or asks for a new wording from the panel or the chat.

## Non-goals
- The tool over ACP or MCP.
- A modal form that stops the turn (`AskUserQuestion` behaviour).

## Sources of inspiration
- **`AskUserQuestion`** (Claude Code). Input: 1–4 questions, each with
  `question`, `header` (a label of at most 12 characters), 2–4 `options`
  (`label`, `description`, optional `preview`) and `multiSelect`. The UI
  always adds "Other" with free text, and the schema tells the model not to
  add one. A recommended option goes first with "(Recommended)" after its
  label. The result is `User has answered your questions:
  "<question>"="<answer>"`, with the selected preview and user notes when
  present.
- **TodoWrite** (Claude Code). The list is not supplied again after
  compaction. A `todo_reminder` lists all items after 10 turns without a
  TodoWrite call, then at most every 10 turns, with the instruction never to
  mention the reminder to the user.
- **TaskCreate / TaskList / TaskGet** (Claude Code). The tool assigns `#id`;
  the model gets the list with TaskList and one entry with TaskGet.
- **`@mrclrchtr/supi-ask-user`** (pi): saves an answered form as a
  "decision" entry in pi's session tree.
- **`@chthub/pi-subagents`** (pi): a subagent sends a question to its parent
  and keeps working.
- **`pi-goals`**, **`@ftrdotdev/pi-tracker`** (pi): extension state that
  survives reload and, for `pi-goals`, compaction.

## To verify
1. A pi extension can add text to the context after compaction (read
   `pi-goals` and pi `extensions.md`).
2. A pi extension can add text to the next user prompt without showing it
   as typed text.
3. pi extensions share one tool namespace: `@arhen/pi-core-ask` states that
   only one extension can register `ask_user_question` in a session.

## Open questions
1. Blocking: is the tool always non-blocking, or can the agent ask for a
   blocking question when it cannot continue without the answer?
2. Input structure. A required question text, plus optional parts:
   - kind: open, choice, permission (yes / no / free text);
   - options with a description each, single or multiple selection, a
     recommended option; "none of these" with free text is always added;
   - context: file paths with line ranges, a link to a chat position;
   - arguments: pros and cons for each option;
   - a short label for the panel, like `header`.
   Which parts are in the first version, and does each kind have its own
   schema or one schema with optional fields?
3. Questions for each call: one, or a list like `AskUserQuestion` (1–4)?
4. Who resolves a question: the agent with an action, the user from the
   panel, or both? Does the agent close a question that the user answered
   in prose without the `Q<n>`?
5. `cc` (rephrase): start a turn at once, or wait for the next prompt so
   that several actions go in one message?
6. Delivery of user actions (answer, dismiss, rephrase) that occur between
   turns: text added to the next prompt, or a message of its own?
7. Compaction: supply the open questions only after compaction, or also a
   periodic reminder like `todo_reminder`?
8. Chat block versus panel entry: how much of the question shows in each?
   Can the user answer in the panel, or only in the input buffer?
9. Number scope: one series per session, and does a fork keep the numbers
   and the open questions?
10. Subagents: do subagent questions go to the same panel, with a source
    label?
11. Reminder delivery for a question in prose: in the next prompt, or a
    follow-up turn (like a blocking stop hook)?
12. Tool name: `ask` or other, given point 3 of To verify.
13. Store owner. Change 1 needs the number in the extension; change 2 puts
    the store in the plugin. One owner:
    - the extension, in pi's session tree (`pi-goals`, `supi-ask-user`),
      with events to the plugin, which only renders; or
    - the plugin, with a synchronous request from the extension per call
      (like the `ctx.ui.select` round trip for permissions).
    This also decides open question 9 and change 7.
14. Completion trigger for open questions: a new trigger character, or `Q`
    followed by a digit as a keyword?
15. User actions between turns meet `InputDispatch:submit` and the prompt
    queue. Is "User dismissed Q3" a queued prose block, or merged into the
    next prompt? (Relates to open questions 5 and 6.)
16. Answered and dismissed questions: do they stay in the store, so that
    `Q<n>` in old prose stays highlighted and `gd` still works?
17. Background and skeptic sessions: do their questions go to the user's
    panel?
18. The reminder for a question in prose fires once per session. After
    compaction the model may have lost it; send it again with change 7?
19. We can also enforce this better by broading the concept from an `ask` tool, 
    to a more general "handing back to user" system, which is simply a 
    structured version of the Stop message. So, we completely block a regular stop 
    message (maybe specifically saying to agent your stop message must be "IDLE", 
    since an agent can't say literally nothing), and then it has to end its turn 
    with a tool call to a structured tool, with fixed fields, e.g.
    - `state`/`status` of
      - `aligning` (communication with the user)
      - `exploring` (learning, gathering info, nothing has been "done", no implementation or real changes)
      - `doing` (implementing, or running things, producing data, etc.)
      - `retro`/`reviewing` (corrections)
      - `finished`/`done`/`completed` (no more actions from agent or user needed for this session)
    If state/status is not finished, that means something is needed from the user, and that something can probably only be a question. Thus, all but one state must come with at least 1 Q:
    `Q`:
    - `permission` Agent wants to do a thing, the question is not about whether it should be done, it is about safety/risk/etc.
      - `allow`
      - `deny`
      - freetext follow up
    - `agreement` Agent wants to do a thing, the question is about if the user agrees that it should be done.
      - `agreed`
      - `disagree`
    - `scope` Agent wants to do a thing. The questions is not about whether it 
      should be done, it's only about who does it. This could become redundant if 
      we tie in context usage to the agent so it gets a signal when it is close 
      to 200k, and if we tie in an agent being able to fork itself, compact 
      itself, spawn subagents more autonomously.
    - `choice` Multiple choice question with convenient way to press "selection option 1/A", but still with a way to give free text response if the question isn't valid (there's 3 options given, but there are more options to consider). This is basically the `AskUserQuestion` plugins.
    - `user` A question with an answer that ONLY exists inside the user's head. Unknowable without asking.
    The structuring can help by having strict character limits. The agent might still be able to provide plenty of context in the general chat log.
    This is just a quick draft and vague idea of the structure. The structure 
      is yet to be determined through thorough research about similar 
      established patterns, and looking at previous session transcripts for the kinds of questions asked and how they may be improved.
      The goal is simple:
      - reduce user fatigue, by providing exactly the context needed to settle a question, or clear ways to use hover help and goto-def etc. to explore the relevant context, in structured consistent formats.
      - convenience: strong integration with key-maps, etc. to make it fast to communicate, and clear to the agent what is being communicated.
      - teach. Systematically separate info to user that is valuable learnings and background, from info directed to help with resolving questions and moving forward.
      - organise to not miss the overview: keep a listing of the questions, so unanswered ones don't get lost in the noise, and so the agent can drop questions clearly when they are answered. With more autonomous forking, etc. it can also become easier to spread out if a session leads down multiple separate paths of work (a bit like the claude `btw` feature).
      The example structure is flawed: there shouldn't be 
      much room for an agent to choose between states freely, like how it will 
      currently use "scope Q" vs "permission Q" vs "choice Q" without a clear 
      principle behind the Q kind.
    Or we don't force the agent to stay quiet with the "IDLE" sentinel, since 
      agent performance might benefit from thinking out load freely, but then 
      we just block it from finishing without an occompanying "hand back to 
      user" tool call, and the agent will know anything not in that will only 
      maybe be read as a general log.
