# Running the harness in a Claude Code cloud session

A claude.ai/code session on this repo runs its own harness, which joins the
CodeMySpec server at `CMS_SERVER_URL`. Nothing in the repo changes: everything
comes from the cloud environment's settings.

## Environment settings (claude.ai/code → environment)

- **Network access:** Custom. Add `dev.codemyspec.com`, plus `builds.hex.pm`,
  `repo.hex.pm`, `hex.pm` and `github.com`, `release-assets.githubusercontent.com` if the
  default allowlist does not already cover them. Also `*.crates.io` and
  `static.crates.io` (Rust NIFs) and `parcel.pyke.io` (ortex downloads ONNX
  Runtime from it; without it, install Microsoft's ORT 1.19.2 release into
  /usr/local/lib by hand), and `archive.ubuntu.com` plus
  `security.ubuntu.com` for `inotify-tools`. Without inotifywait the harness's
  file watcher cannot start and the project channel rejoins about once a second.
- **Environment variables:**

      CMS_SERVER_URL=https://dev.codemyspec.com
      CMS_HARNESS_PORT=4004
      CMS_DEPLOY_KEY=<the code_my_spec project's deploy key>

- **Setup script:** paste `setup.sh` in full.

The script in this directory is the repository-development setup using a project
deploy key. The device UI generates a separate setup using a proxy network secret.
Both pass `CMS_HARNESS_PORT` to the harness and Claude settings. Use a plugin version
that supports this override; older published plugins have a fixed port of 4003.

`dev.codemyspec.com` is the local `mix phx.server` on :4000 behind the Cloudflare
tunnel, so the Mac has to be up and serving for the cloud harness to join.

## What happens in a session

The setup script installs OTP 28.1, Elixir 1.19.4 and sops, and installs the
`codemyspec` plugin (hooks and MCP on `localhost:4004`). It also adds a
SessionStart hook, `cms-cloud-session`, which runs only when `CLAUDE_CODE_REMOTE`
is `true` and does this, detached:

1. `git submodule update --init` for `.code_my_spec`
2. `mix cms.harness.onboard . --server-url $CMS_SERVER_URL`
   on the first session; it writes the gitignored `.cms_harness.json`, including
   the deploy key used to authenticate. Keep this file untracked. The script reads
   `CMS_DEPLOY_KEY` only from the environment and never embeds its value in scripts
   or settings.
3. starts the harness from source on :4004 (`MIX_ENV=harness mix run --no-halt`)
4. once the harness has joined and installed the project's age keys, decrypts
   `envs/dev.env` and `envs/test.env` for the analyzers

The first boot compiles, so the harness is not up for several minutes. Hooks and
the `local` MCP server fail until it is; run `/mcp` to reconnect after that.

## Checking it

    tail -f ~/.codemyspec/cloud-session.log   # the hook's own steps
    tail -f ~/.codemyspec/harness.out         # compile and boot output
    tail -f ~/.codemyspec/harness.log         # [CmsHarness] lines: join, scans
    curl -s localhost:4004/health

On the Mac side the cloud copy shows up in `web.log` joining
`harness_project:<id>`.
