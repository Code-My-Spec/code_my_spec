# Codex Cloud dev boxes

The Dev boxes page emits an installation bundle for a Phoenix generation target,
a startup command for fresh or resumed machines, and a session command for each
Codex conversation. Run these from the target repository, not the harness source.

Installation pins Erlang/Elixir from `.tool-versions`, resolves locked target
dependencies, and installs the Linux harness separately. Startup preserves
database and credential state, validates the target, requests device authorization
when necessary, and waits for a connected watcher. Source changes invalidate prior
validation. Each conversation uses its own `CODEX_THREAD_ID` and completes the MCP
initialize/initialized handshake before checking task tools.

Private machine state defaults to `~/.codemyspec/codex-cloud/<device-id>`.
`CMS_CLOUD_STATE_DIR` changes that directory. Source its `environment.sh` before
running target Mix commands. `CMS_HARNESS_PORT` selects an unused loopback port;
startup refuses to reuse a harness belonging to another device or project.

## Release requirement

Ship the server/provider and a Linux harness release containing `CMS_STATE_DIR`,
the configurable WebSocket proxy options, and `/health`'s `device_id` together.
Older binaries cannot satisfy readiness. The default archive version comes from
the server release; `CMS_HARNESS_VERSION` can pin another published release.
Development builds can explicitly set `CMS_HARNESS_ARCHIVE` to a locally built
tarball. Never embed OAuth credentials in either bundle.

## Verification

Story 1146's Spex scenarios exercise the UI, OAuth endpoints, lifecycle CLI and
per-thread MCP handshake using controlled external harness/database boundaries.
They do not prove that a published binary installs and connects on a clean image.
Before promotion, run the emitted bundle on a fresh target, approve its device
grant, verify `check` and `session`, and repeat startup after a process restart.
Verify target compilation, assets and migrations, persistent database data, and
separate conversation identities. Keep QA credentials outside the repository.
