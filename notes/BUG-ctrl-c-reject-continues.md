# Bug: `<C-c>` at a permission prompt rejects, and the agent continues

While claude is writing prose, `<C-c>` works — it stops claude completely.
While claude prompts for allow for editing a file, `<C-c>` rejects, but then
claude starts thinking and gives a response like "I was trying to do x and
since I couldn't here's the instructions for you to do it".

## Expected

`<C-c>` stops and blocks claude fully in all scenarios (but not persistent
stopping based on task etc.). The numbered options are for other reject
behaviours.
