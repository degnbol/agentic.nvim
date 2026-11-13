# Idea: a queued message answers a question that was never seen

The queue shipped in `f170629` and `19fa6d6`. The risk that motivated
holding it back is only partly addressed.

Queueing is for releasing the next task without interrupting the agent, but
the turn may end with a question rather than finished work — and the queued
message answers a question that was never asked. Narrowing the drain to a
normal Stop covers the cases where the turn visibly did not finish
(`<C-c>`, `refusal`, `max_tokens`, an error): those park the queue. It does
not cover a turn that ends `end_turn` *with* a question in its summary,
which is the common shape.

The agent may or may not repeat an unanswered question. Mitigating this
needs a way to tell "finished" from "asked" at Stop — worth solving before
leaning on the queue harder.
