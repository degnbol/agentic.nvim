# Bug: prose with two dollar amounts is wrapped as inline math

Found by a read-only audit (2026-10-26); not reproduced.

## Observed in code
`lua/agentic/utils/text_wrap.lua:26-59` (with :91-99, :426, :440-455) keeps `$…$` spans atomic when hard-wrapping prose. Ordinary prose such as `costs $5 and $10` pairs the two dollar signs as a math span, so `$5 and $` becomes one unbreakable word.

## To establish
Which delimiter rule the chat's math rendering uses (the user's nvim config renders `$…$` as images; see the `math-images` skill in the parent config), so wrapping and rendering agree on what counts as math. Pandoc's rule, for example: the opening `$` is followed by a non-space and the closing `$` is preceded by a non-space and not followed by a digit.
