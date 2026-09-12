# Writing a Spex

## File layout

```
test/spex/<story_number>_<story_slug>/criterion_<criterion_number>_<criterion_slug>_spex.exs
```

Worked example — story **id** 1031, whose **number** is 1065:

```
test/spex/1065_every_process_an_agent_is_expected_to_follow_is_written_down/
  criterion_3379_an_agent_finds_the_process_without_reading_the_code_spex.exs
```

**The directory is named from the story's number, not its id.** Every MCP tool
takes the id, so the id is the number you are holding when you come to do this,
and it is the wrong one. They are different integers that coincide on a young
project, which is what makes the assumption survive. `get_story` returns both.
See `process/product.md`.

One file per acceptance criterion. Module name mirrors the path, and uses the
same number:

```elixir
defmodule <App>Spex.Story<story_number>.Criterion<criterion_number>Spex do
```

## Minimal template

```elixir
defmodule <App>Spex.Story<id>.Criterion<id>Spex do
  @moduledoc """
  Story <n> — <story title>
  Criterion <n> — <what this criterion asserts in plain language>
  """

  use <App>Spex.Case

  import <App>Spex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "<engineer/agent> does <action>" do
    scenario "<observable outcome>" do
      given_ :synced_context_component
      given_ :on_configuration_page

      when_ "<single user action>", context do
        # drive the UI or the hook endpoint
        {:ok, context}
      end

      then_ "<observable assertion through the public surface>", context do
        # observe via rendered HTML, HTTP response body, or LiveView element
        {:ok, context}
      end
    end
  end
end
```

## What each piece does

- `use <App>Spex.Case` — wires up ConnTest, LiveViewTest, the
  SexySpex DSL, the DB sandbox, and the `Fixtures` bridge.
- `import <App>Spex.SharedGivens` — a plain `import`; makes `given_ :atom`
  shortcuts available for common setup.
- `setup :register_log_in_setup_account` — registers a user, logs them
  in, activates an account.
- `setup :setup_active_project` — creates a project, attaches a fresh
  in-memory environment to it, registers the env so LiveViews rebuild
  scope against the same memfs. **Always pair it with the auth setup
  above.**

## DSL: `given_`, `when_`, `then_`

Every step — `given_`, `when_`, `then_`, `and_`, and registered
givens — **must** return `{:ok, context}`. A bare `:ok` is rejected at
runtime (`SexySpex.Runtime` raises `must return {:ok, context}`).
Returning `{:ok, context}` (optionally with new keys merged into the
map) makes those keys visible to every later step. A `then_` that only
asserts and changes nothing still returns `{:ok, context}` unchanged.

### `given_ :name` — shared given

Invokes a step registered in `<App>Spex.SharedGivens`. Use these
for setup that recurs across specs.

### `given_ "text", context do ... end` — inline given

Establishes state for *this* scenario. Free to reach for fixtures on
the bridge or drive the UI/hooks. Don't assert here — a raise or
pattern-match failure at the point of failure is fine; `then_` is for
outcome assertions.

### `when_ "text", context do ... end`

The one user action under test. Keep it to a single LiveView
interaction or one hook POST. If you need two actions, you probably
need two scenarios.

### `then_ "text", context do ... end`

Observe through the public surface only. **Never read the DB in a
`then_` step** — use the rendered HTML, the HTTP response body, or a
LiveView element query. Multiple `then_` steps are fine and often
read better than one big assertion block.

## The context map

Whatever a step returns as `{:ok, map}` is merged into `context` and
visible to all later steps. Useful keys produced by standard setup:

| Key | Source | What it is |
|---|---|---|
| `conn` | Case setup | Authenticated `Plug.Conn` |
| `user` | `:register_and_log_in_user` | The logged-in user |
| `account` | `:setup_active_account` | The active account |
| `project` | `:setup_active_project` | The active project row |
| `scope` | `:setup_active_project` | A `%Scope{}` with `cwd` + `environment` |
| `environment` | `:setup_active_project` | The in-memory env |
| `component` | `:synced_context_component` | Component produced by real sync |
| `config_live` | `:on_configuration_page` | The mounted configuration LiveView |

## Anchor assertions: don't write vacuous refutes

When a `then_` is mostly `refute html =~ "..."`, include at least one
positive assertion for something that *should* still be present. This
proves the graph/page/response actually has content — without the
anchor, an empty string would pass every refute:

```elixir
# Good — anchor proves the page rendered at all.
assert html =~ "implementation_file"
refute html =~ "spec_file"
refute html =~ "spec_valid"
```

See `5081_spex.exs` through `5085_spex.exs` for the pattern.

## Driving the LiveView (engineer actions)

```elixir
{:ok, config_live, _html} =
  live(context.conn, ~p"/projects/#{context.project.name}/configuration")

config_live
|> form("[data-test='configuration-form']", configuration: %{require_specs: false})
|> render_submit()
```

Prefer `data-test` selectors over class or id — they are test-only,
stable, and declare intent. Use `has_element?/2` to assert on rendered
state without scraping HTML.

## Driving the agent surface (hook actions)

```elixir
response = post_hook(context, "/api/hooks/stop", %{})
```

`post_hook/3` sets `x-harness-id`, dispatches to the **local** endpoint
explicitly, and returns the decoded body. Take the helper rather than
building the conn: hooks are a harness-app surface, and a hand-built conn
dispatches through whatever `@endpoint` the spex file declares — which is
the cloud app in at least one file.

A request names the working copy, never a path. `x-working-dir`, `?dir=`,
`Plugs.WorkingDir` and `WorkingDirScope` were removed because resolving a
checkout from an announced path succeeded against the wrong disk rather
than failing when it was wrong.

## Writing files as "the agent"

```elixir
alias <App>.Environments

:ok = Environments.write_file(context.environment, "lib/example_context.ex", contents)
```

Every file the agent would create must go through `Environments.write_file/3`
against `context.environment`. This is what the memfs interprets, and it's
what the sync pipeline will pick up when the LiveView sync button runs.

## Running specs

```
mix spex                                    # whole suite
mix spex test/spex/1065_every_process_...   # one story, by its NUMBER
mix spex --pattern "test/spex/1065_*/*_spex.exs"   # same, without typing the slug
```

`mix spex` is aliased in `mix.exs` to `spex --quiet` under `MIX_ENV=test`.
