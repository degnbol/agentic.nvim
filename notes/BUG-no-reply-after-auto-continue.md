# Bug: no reply shown after auto-continue

After auto-continue after reaching a limit the "Continue" is sent correctly
to chat but then nothing appears in chat from the model.

After closing the program (nvim), restarting and resuming the session a
response is visible immediately in chat, i.e. the continue was successful
but the chat didn't show the response from the model.

This is a long standing and difficult bug.
