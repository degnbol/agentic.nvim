# Bug: tar ask gates miss letters in an old-style bundle
Status: draft

## Relevant files
- `lua/agentic/permissions.json` — `tar` entry
- `lua/agentic/utils/permission_structured.lua` — positional gates
- `lua/agentic/utils/permission_structured.test.lua`

## Background
tar accepts an old-style first word with no dash: `tar tf x.tar`, `tar fI
x.tar prog`. The matcher reads it as a positional, so tar's ask gates on
`options` (`c`, `x`, `I`, `use-compress-program`, …) never see its letters.
The hole is reached when another word satisfies an allow gate:

- `tar tfI x.tar prog` approves through `positionals: ["t*"]`. The allow
  ∀ reading does not close it: the bundle is a positional in every parse.
  Deleting the gate closes it and costs the corpus's `tar tzf …` approvals.
- `tar fI x.tar prog -t` approves through `options: ["t"]`: `-t` counts
  after the plain word `prog`.

GNU tar reads `fI` as options and runs `prog` (unmeasured: no GNU tar here).
bsdtar 3.5.3 reads `I` as an include list (measured).

## Changes
Options to decide:
- An ask gate on tar's first word when it has no dash. Needs a "first
  word" anchor; positional patterns are index-based over the parse stream,
  so the gate must not fire on member names after `-f x.tar`.
- A tar-specific rule: read a dashless first word as a cluster for deny/ask
  candidates (spelling knowledge for one command).
- Drop tar's option-keyed `read_only` gate; `tar -tf` then prompts.

Each option also decides the `t*` gate: delete it, or keep it once the
first-word ask covers bundles.

## Expected outcome
A tar command with an old-style first word never approves when that word
holds an ask letter.

## Open questions
1. Which of the three changes?
