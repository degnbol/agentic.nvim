# Idea: check the provider service before offering a login

An auth error can come from a provider outage, not from expired credentials.
`Recovery.offer_login` points the user at `/login` at once, so a login during
an outage fails or succeeds without effect.

Before the offer, check that the provider's service answers (for example an
HTTP request to its API host). While it does not answer, write that it is
unreachable and check again with a backoff. Offer `/login` only after it
answers.

Open points:
- The service URL is provider-specific, so it belongs to the adapter, with no
  check as the neutral default.
- A pending check must stop on `/new`, a load, `:bd` and a successful turn.
