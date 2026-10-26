# Bug: a multi-element deny gate rejects without a prompt above the flag cap

Found by a read-only audit (2026-10-26); not reproduced. Reachable only through user config; no bundled gate is affected.

## Observed in code
`lua/agentic/utils/permission_structured.lua:102-108, 516-520`: `MULTI_ELEMENT_FLAG_CAP` bounds matching time for multi-element gates. Its comment says exceeding the cap "only over-prompts". The deny path uses the same matcher, so above the cap a multi-element deny gate matches conservatively and rejects with no prompt.

## Expected
Above the cap, both allow and deny gates fall back to asking the user.

## Related
`permissions` skill and `references/parsing.md`.
