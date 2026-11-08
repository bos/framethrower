# Native Director sessions

The built-in Director invokes official account-authenticated Claude and Codex
CLIs, or the pinned Qwen Code CLI with the local Metal model server. It does not
automate their desktop interfaces. Each turn resumes the provider's exact native
conversation; the provider runtime owns its transcript, tool loop, caching and
compaction.

`director-agent-client.py` serializes turns and stores only provider, model,
persistent recording identity and native session ID in an owner-only directory.
It submits the new user message and actual editor events. It does not reconstruct,
summarize or trim model history. Bootstrap metadata is supplied only on the first
turn. Changing models within a provider family retains that conversation; another
recording or provider family has a separate native session.

The native runtime receives only FrameThrower's MCP server, scoped to one open
recording. Native agent operating-system, shell and unrelated app tools are
disabled. Normal editing validation, revision checks, conflict review and Undo
remain the editor's responsibility. Failed or cancelled turns can have completed
edits; their actual effects remain visible and undoable. Never retry by silently
starting a fresh conversation.

Qwen Code 0.27.0 is installed under FrameThrower's private cache, without changing
the user's Qwen settings. Its upstream estimator adds a 20,000-token safety pad;
the local server and provider therefore both advertise the same actual 32,768-token
context. The server remains warm between turns and shuts down when FrameThrower
quits. This is runtime configuration, not an app-side conversation budget.

Offline checks use fake CLIs or synthetic HTTP/MCP peers. The optional
`Tests/check-native-director-live.sh` explicitly opts into a signed-in provider
against a disposable metadata-only editor and private socket. It never opens the
GUI or creates, decodes or renders video. Model latency and cache results from
that test are smoke-test observations, not comparative benchmarks.
