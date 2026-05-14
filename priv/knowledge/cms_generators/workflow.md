# CodeMySpec Generators — Workflow

The standard CodeMySpec scaffold runs five generators in order. Each
generator depends on the previous one's output, so the order is fixed.

## Generator order

1. `mix phx.gen.auth Users User users --live` — authentication with
   registration, login, and session management. Sets up `lib/<app>/users/`.
2. `mix cms_gen.accounts` — multi-tenant accounts with members and
   invitations. Depends on the auth scaffold from step 1.
3. `mix cms_gen.integrations` — OAuth integration scaffolding with
   encrypted token storage. Depends on auth.
4. `mix cms_gen.integration_provider <DisplayName> <key>` — one per OAuth
   provider you need. Depends on `cms_gen.integrations`. See "Integration
   providers" below.
5. `mix cms_gen.feedback_widget` — CodeMySpec feedback widget with
   screenshot capture. Depends on `cms_gen.integrations`.

## After every generator

Run these in order before moving to the next generator:

1. `mix deps.get` — if the generator added new dependencies.
2. `mix ecto.migrate` — apply any new migrations the generator produced.
3. `mix compile` — confirm the project still compiles before continuing.

If any step fails, stop and fix the underlying issue. Don't skip ahead.

## Integration providers

When integration specs exist in `.code_my_spec/integrations/*.md` (one file
per provider), run `mix cms_gen.integration_provider <DisplayName> <key>`
for each. The `<key>` is the lowercase identifier; `<DisplayName>` is the
user-facing name used in OAuth UI strings.

Examples:

    mix cms_gen.integration_provider GitHub github
    mix cms_gen.integration_provider Google google
    mix cms_gen.integration_provider CodeMySpec codemyspec

The provider key should match the filename stem in
`.code_my_spec/integrations/` (so `github.md` → `github`).

## When everything is done

1. Run `mix compile` and resolve any remaining warnings or errors.
2. Run `mix ecto.migrate` to apply all pending migrations.
3. Run `mix test` to verify nothing is broken.
4. Write the reproducible script to `.code_my_spec/tasks/code_generation.sh`
   — see [script-format.md](script-format.md).

The evaluator only checks that the script exists and is non-empty. Compile
and test failures don't gate the task, but downstream tasks will fail if
you skip them.

## After `cms_gen.feedback_widget` — multi-step setup

When `mix cms_gen.feedback_widget` completes, it prints a multi-step setup
procedure to stdout. Follow it — most of those steps are configuration
edits the agent can apply directly. The generator's stdout output is the
source of truth for env var names, config keys, and module paths.

The standard steps the generator emits cover:

- Run `mix cms_gen.integration_provider CodeMySpec codemyspec` if not
  already run — the widget depends on it.
- Add `:codemyspec` to `:oauth_providers` and `:integration_providers`
  in `config/config.exs`.
- Add `:codemyspec_url` to `config/config.exs`.
- Add `:codemyspec_url`, `:codemyspec_client_id`, `:codemyspec_client_secret`
  to `config/runtime.exs` reading from env vars (typically
  `CODEMYSPEC_URL`, `CODEMYSPEC_CLIENT_ID`, `CODEMYSPEC_CLIENT_SECRET` —
  but the generator's output is authoritative).
- Add the `<.live_component>` block to `root.html.heex` (not `Layouts.app`
  — `live_component` can't render in dead views).
- `cd assets && npm install html-to-image`.
- Add `import "./screenshot"` to `assets/js/app.js`.

The agent should apply these idempotently — re-read config files first and
only add what's missing, since this task is re-runnable.

### Credentials — relay to engineer (the one step the agent cannot do)

The `CODEMYSPEC_CLIENT_ID` and `CODEMYSPEC_CLIENT_SECRET` values are
generated on the CodeMySpec server, not in the local app. The agent task
renders the engineer's exact project URL in the prompt. Tell the engineer:

1. Open the project URL from the agent's summary message.
2. Click the **Generate Credentials** button on the project page.
3. Set the resulting client ID and client secret as runtime env vars
   before deploying. Read `config/runtime.exs` for the exact env var
   names if uncertain — the agent should have wired up runtime.exs
   already in the previous step.

Without these credentials in env, the widget compiles cleanly but
authentication fails at runtime when users send feedback. Surface this
explicitly in the agent's summary — don't bury it in script comments.
