# Bug: punctuation highlight lands on random cells of markdown tables

`AgenticClean__punctuation_special_markdown` is showing up in seemingly
random places in markdown tables.

My guess is it's placed correctly for the `|` delimiters before we do my
custom auto-align of tables which then leaves it highlighting random
letters.

The fix might simply be to remove the code adding
`AgenticClean__punctuation_special_markdown`, what is it used for? We have
proper hl of `|` in md tables already.
