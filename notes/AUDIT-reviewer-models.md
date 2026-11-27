# Audit: can an opencode model replace Opus as reviewer
Status: draft
Priority: P2
Depends:

Input to part 6 of `TRACK-token-usage.md`. Review subagents use about 10% of
the Claude limits, and plan-reviewer 3–5% (`/usage`, 2026-11-13). A LiteLLM
model through opencode uses none.

## Relevant files
- `~/dotfiles/config/claude/agents/code-reviewer.md`, `plan-reviewer.md`
- `~/dotfiles/config/opencode/opencode.json` (models), `opencode.base.json`
- Transcripts: `~/.claude/projects/*/` (subagent reviews and what followed)
- Skills: `claude` (`references/subagents.md`)

## Background
"Good enough" has two parts:
- **Recall**: the reviewer finds the defects that Opus finds.
- **Noise**: the main Claude session checks each finding, and that work
  counts toward the limit. False findings move usage back into the main
  session.

The test runs headless, without agentic.nvim plumbing:
`opencode run -m litellm/<model> --agent <reviewer> "<task>"`.

## Changes
1. **Test set.** From transcripts, pick 10 code reviews and 5 plan reviews
   whose findings the main session applied. Take the input of each (the
   commit range or the plan file at that time) from git. The ground truth is
   the applied findings. Store it as one TSV per case:
   `id, file, line, summary`.
2. **Equal access.** Make the reviewer prompts and skills available to
   opencode as agents, so each candidate gets the same instructions and the
   same read access. If opencode cannot load a skill, inline that skill's
   text for every candidate, Opus included.
3. **Runs.** Run each case with Opus 5.5 (baseline), Sonnet 5.5, and the
   opencode models `kimi-k3`, `glm-5.3` and `wandb-deepseek-v4-pro-0813`.
   Use a checkout at the case's commit.
4. **Adversarial pairs from two labs.** Two agents, one per opencode model
   from different labs, review in parallel. Then, in its own session, each
   attacks the other's findings once, with no exchange back (no debate).
   Each finding is a defect (falsifiable) or a suggestion (an opinion).
   For a defect the attacker gives one verdict:
   - `refuted`: needs evidence (file and line, or a command and its
     output). The finding is dropped.
   - `unsure`: kept, with a one-line counterpoint.
   - `stands`: kept, with no comment.

   A suggestion is never dropped; the attacker may add a counterpoint. The
   report has the kept findings, their counterpoints, and the number of
   dropped defects. Verdicts use the skeptic's format
   (`skeptic/verdicts.lua`); the attack prompt is new. Score also:
   - Union of the two reviews before the attack, to measure what the
     attack removes.
   - Real defects (by the ground truth) marked `refuted`, to measure
     whether the attacker's own review or the adversarial framing biases
     it.
5. **Scoring.** For each run or pair, match each defect to the ground truth:
   hit, false, or new. A "new" defect is valid but not in the ground truth.
   The user judges the "new" defects once per defect, not once per run.
   Record recall, the number of false defects, and the tokens the reviewer
   used. Suggestions are not true or false: count them, and the user rates
   each once as useful or not. A factual claim labelled a suggestion counts
   as a defect.
6. **Result.** One table per candidate and pair. A candidate or pair passes
   with recall at least 80% of Opus's and at most 1 false defect per
   review.

## Expected outcome
A measured answer to whether part 6 can send reviews to opencode, and which
model to use.

## Non-goals
- The delegation plumbing (part 6 of `TRACK-token-usage.md`).
- Reviewers other than code-reviewer and plan-reviewer.
