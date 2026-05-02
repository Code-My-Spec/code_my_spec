# Shared Givens

Shared givens live in `test/support/shared_givens.ex`
(`<App>Spex.SharedGivens`). They are atom-named steps that
multiple specs can invoke with `given_ :name`.

## When to add one

**Rule from the module itself:** add a new shared given only after a
_third_ spec duplicates the same setup. Two duplicates is still cheap
to read inline; three is where the pattern is worth naming.

Until then, inline the given with a descriptive sentence:

```elixir
given_ "the implementation file has been mutated with credo violations",
       context do
  :ok = Environments.write_file(context.environment, @impl_path, messy_impl())
  {:ok, context}
end
```

## What a shared given looks like

```elixir
given :synced_context_component do
  scope = context.scope
  env = context.environment

  :ok = Environments.write_file(env, @spec_path, spec_file_content())
  :ok = Environments.write_file(env, @impl_path, impl_file_content())

  {:ok, sync_live, _html} =
    live(context.conn, "/projects/#{context.project.name}/sync")

  sync_live |> element("button[phx-click='sync']") |> render_click()

  component =
    Fixtures.get_component_by_module_name(scope, @component_module_name)

  {:ok, %{component: component}}
end
```

Properties to preserve:

- **Establishes state, does not assert.** A shared given should not
  include `assert` statements about the system under test. If setup
  breaks, let it break loudly at the point of failure (pattern-match
  failure, `{:ok, _}` mismatch). Assertions belong in `then_`.
- **Produces keys.** Return `{:ok, %{key: value}}` so downstream steps
  have something to reference. Document which keys the given adds in
  the `SharedGivens` moduledoc.
- **Goes through the real surface.** The given above writes files and
  clicks the sync button — it does not call `Components.create/2`.
- **Depends on prior keys, not on prior givens.** If a given needs
  `context.component`, declare that in its doc ("Requires
  `context.component` from a prior given"), and let the scenario
  author order them correctly. Don't call other givens from inside a
  given.

## Current shared givens

| Name | Produces | Requires |
|---|---|---|
| `:synced_context_component` | `context.component` | — |
| `:story_linked_to_component` | `context.story` | `context.component` |
| `:on_configuration_page` | `context.config_live` | — |
| `:bdd_task_started` | `context.session_id` | `context.story` |

Keep this table updated when you add or remove a shared given.

### `:bdd_task_started`

Drives the real agent contract for starting work on a story's BDD
specs: POSTs to `/api/hooks/session-start` with a unique `session_id`,
then invokes `<App>.McpServers.Tasks.Tools.StartTask.execute/2`
directly with a minimal `%Anubis.Server.Frame{}`.

This creates a real active task on the session whose `session_type` is
`<App>.AgentTasks.WriteBddSpecs` — that module's `analyzers/0`
returns `[:spex_stale]`, so when the stop hook runs for a session with
this task active the pipeline runs `mix spex --stale`. Without this
given, `:spex_stale` is never in the analyzer list.

Specs that use this given must pass `context.session_id` in the stop
hook POST body:

```elixir
post(~p"/api/hooks/stop", %{
  "session_id" => context.session_id,
  "test_output_files" => %{ ... }
})
```

## Naming

- Use snake_case atoms that describe the _state_, not the action.
  `:synced_context_component` (a component exists that has been
  synced) is better than `:sync_a_component` (an action you took).
- Prefer one concept per given. If you're tempted to combine
  "component exists" + "story linked," make them two givens and let
  the scenario compose them — that's what the shared-givens DSL is
  for.
