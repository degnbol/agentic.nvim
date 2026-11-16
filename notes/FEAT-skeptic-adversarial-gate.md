# Plan: skeptics attack each other's refutations instead of voting
Status: spec
Priority: P2
Depends:

## Relevant files
- `lua/agentic/skeptic/init.lua` (`_check`, `_verify`, `deliver_text`,
  `_on_agent_destroyed`)
- `lua/agentic/skeptic/reporting_criteria.lua` and its test (removed)
- `lua/agentic/skeptic/prompts.lua` (`DEFAULTS`, `PromptKey`)
- `lua/agentic/skeptic/verdicts.lua` (`parse`)
- `lua/agentic/skeptic/init.test.lua` (`answer`, the reporting tests)
- `lua/agentic/background_session.lua` (`prompt`, closed sessions)
- `lua/agentic/config_default.lua` (`skeptic`)
- `doc/agentic.txt` § agentic-skeptic
- `notes/TRACK-token-usage.md` part 6 (the shared pipeline)
- Skills: `subagents`, `implement`, `lua-class`; rule `help.md`

## Background
Checks share one pipeline (`TRACK-token-usage.md` part 6): checkers on
models from different labs check the input, then each attacks the others'
findings once, with no debate. Dropping a finding needs evidence. Keeping it
does not. For the skeptic, the items are the extracted claims and a finding
is a refutation with evidence.

The cross-check logic knows nothing about claims, so it lives outside
`skeptic/` for the review trigger (`FEAT-cross-lab-review.md`) to reuse.
There each reviewer writes its own findings, and an attack's other answers
are shown as counterpoints. So `assign` takes who may attack what, not the
skeptic's verdicts, and the attack result is each objection's answers, not
a kept set.

Rules:
- A refutation needs evidence. A `refuted` verdict with empty evidence is
  not a finding. So a claim every skeptic refuted without evidence, which
  `"agree"` forwards today, is no longer forwarded.
- A checker attacks the objections to items it did not mark `refuted`
  itself, by the verdict word, with or without evidence. A checker that
  gave no verdicts (failed, or a reply without a verdict block) does not
  attack. This keeps a check from waiting behind a stuck session.
- An attack `refuted` with evidence drops the objection. Any other answer,
  or no answer, keeps it silently. A skeptic speaks only with evidence, so
  an attacker's doubt (`unsure`) adds nothing to the delivery.
- With one checker, or when every checker refuted the item, nothing is
  attacked. This follows from the rules, with no special case.

## Changes
`lua/agentic/skeptic/verdicts.lua` and its test move to
`lua/agentic/cross_check/verdicts.lua`; the types become
`agentic.CrossCheck.Verdict` and `agentic.CrossCheck.VerdictWord`.

New `lua/agentic/cross_check/init.lua`:
- `--- @class agentic.CrossCheck.Objection`
  `{ item: integer, checker: integer, evidence: string }`.
- `CrossCheck.objections(n_items, per_checker): agentic.CrossCheck.Objection[]`:
  each `refuted` verdict with non-empty evidence for items `1..n_items`, in
  item then checker order. `per_checker[i]` is checker `i`'s verdicts by
  item number, or false. Numbers outside `1..n_items` are ignored.
- `CrossCheck.assign(objections, stances): table<integer, agentic.CrossCheck.Objection[]>`:
  `stances[c]` is false for a checker that does not attack, else the set
  of items it objected to itself (`table<integer, true>`). Checker `c`
  attacks objection `o` when `stances[c]`, `o.checker ~= c`, and not
  `stances[c][o.item]`. Only checkers with at least one objection are
  keys. The skeptic's stances: false for a checker without verdicts, else
  the items it marked `refuted`, with or without evidence.
- `CrossCheck.answers(assigned, attack_verdicts): table<agentic.CrossCheck.Objection, table<integer, agentic.CrossCheck.Verdict>>`:
  `attack_verdicts[c]` is checker `c`'s verdicts by the objection's number
  in `assigned[c]` (from 1, in order), or false. Each assigned objection's
  answers, keyed by the attacking checker. Unassigned objections are
  absent; callers read them as `{}`. Numbers outside a checker's list are
  ignored. Keyed by object identity, so the numbering stays inside this
  function.
- `CrossCheck.refuted(answers): boolean`: whether one of `answers` (one
  objection's value from `answers`, or nil) is `refuted` with non-empty
  evidence. The one place of the evidence rule for dropping.

`lua/agentic/background_session.lua`:
- `BackgroundSession.prompt_all(sessions, texts, on_done)`: sends
  `texts[i]` to `sessions[i]` for `i = 1, #sessions`, in parallel, skipping
  nil texts. `on_done` gets `results[i] = { text, err }` (the `prompt`
  callback's arguments), or false for a skipped session, once all
  answered. The pending count is the number of non-nil texts, set before
  the loop, since a closed session answers synchronously. With none,
  `on_done` runs at once.

`lua/agentic/skeptic/init.lua`:
- `agentic.skeptic.Finding` moves here from `reporting_criteria.lua`,
  unchanged (`{ claim: string, evidence: string[] }`), with the evidence of
  the kept refutations only.
- New `Skeptic:_ask(agents, texts, on_done)`, extracted from `_verify`:
  `BackgroundSession.prompt_all` over the agents' sessions, with the
  generation check and the failure notifies of today. `on_done(per_agent)`
  gets each agent's parsed verdicts or false.
- `_verify` builds the verify text for each agent and calls `_ask` with a
  copy of `self._agents`, taken before the prompts go out. `on_done` gets
  that copy, so later calls address the same agents after
  `_on_agent_destroyed` changes `self._agents`. A destroyed agent's session
  answers "closed", which drops nothing.
- `_check`: after `_verify` and the `_checked` bookkeeping (unchanged),
  `CrossCheck.objections` and `CrossCheck.assign`. With no assignment,
  deliver at once. Else `_ask` the copied agents with the `attack` texts,
  `CrossCheck.answers`, then deliver the claims with an objection for which
  `CrossCheck.refuted` is false.
  `deliver_text` is unchanged.

`lua/agentic/skeptic/prompts.lua`:
- `PromptKey` gains `"attack"`.
- New `attack` prompt. `%s`: the other skeptics' refutations, numbered, each
  with its claim and evidence. The user prompts and diffs are not resent;
  the session has them from `verify`. It asks the skeptic to find holes in
  each refutation and to list only the refutations it shows to be wrong,
  each with evidence, as `refuted` entries in the `verify` json block. The
  prompt says that the `"claim"` key holds the refutation's number. Other
  verdict words are accepted and ignored.

`lua/agentic/skeptic/reporting_criteria.lua` and its test: removed.

`lua/agentic/config_default.lua`: remove `reporting_criteria` and its
`@field`. Add `attack` to the keys in `@field prompts`. `max_refusals`
reads "Refusal prompts per skeptic prompt".

`doc/agentic.txt` § agentic-skeptic:
- The second sentence becomes: "Claims a skeptic refutes with evidence go
  to the main agent as one prompt marked with the skeptic's sign, unless
  another skeptic shows with evidence that the refutation is wrong."
- Remove the `reporting_criteria` entry.
- Add `attack` to the prompt keys. `max_refusals` reads "per skeptic
  prompt".

Tests:
- `background_session.test.lua`: `prompt_all` answers once all sessions
  answered, skips nil texts, and answers when a session is closed.
- `cross_check/init.test.lua`: `refuted` without evidence is no objection;
  numbers out of range ignored, in verify and attack verdicts; an item every
  checker refuted is not assigned; a checker that refuted an item without
  evidence does not attack it; a checker without verdicts does not attack;
  one checker gives no assignment; three checkers, one objection attacked by
  two, dropped by one evidence-backed attack; attack `refuted` without
  evidence keeps it; `unsure` keeps it; a skipped number keeps it.
- `init.test.lua`:
  - `answer()` gets a variant that answers one agent's last prompt.
  - "sends nothing when no claim meets the reporting criteria" becomes: one
    skeptic refutes, the other's attack refutes with evidence, nothing is
    delivered.
  - "forwards a claim every skeptic refutes" also checks that no attack is
    sent.
  - An attack `refuted` with evidence drops the claim; an attack `unsure`
    delivers it as without an attack.
  - Disable or session change during the attack drops the delivery.
  - A turn that ends during the attack runs after delivery.
  - A failed attacker drops nothing and notifies.
  - An agent replaced between verify and attack: the attack goes to the
    copied agent, whose closed session drops nothing.

## Expected outcome
A refutation from one skeptic reaches the main agent unless another skeptic
shows evidence that it is wrong. The delivery format is unchanged. The
`reporting_criteria` option is gone.

## Non-goals
- The review trigger of the pipeline (`TRACK-token-usage.md` part 6).
- The extractor and the `verify` prompt. `verify` offers `unfalsifiable`,
  which `Verdicts.parse` drops; that is a separate defect.
