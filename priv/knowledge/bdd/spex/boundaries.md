# Boundaries — what a spec is allowed to call

Specs live in a sealed boundary. They cannot import the core app,
cannot call contexts, cannot touch `Repo`. The only doors are:

- `<App>.Environments` — the filesystem abstraction (read/write
  into the in-memory env). Provided by the harness; specs interact
  with it only through `<App>Spex.Fixtures` or, where the framework
  exposes it, directly.
- `<App>.McpServers` — the MCP tool modules (e.g.
  `StartTask.execute/2`) that the agent invokes as part of the real
  contract. Used only from shared givens that drive the agent surface.
- `<App>Spex.Fixtures` — the approved bridge for DB-originated
  state.
- `<App>Web` (and any secondary Phoenix endpoint such as `<App>LocalWeb`)
  — the Phoenix endpoints. Used indirectly via `Phoenix.ConnTest` and
  `Phoenix.LiveViewTest`.

This is declared in `test/spex/<app>_spex.ex`:

```elixir
use Boundary,
  top_level?: true,
  deps: [
    <App>.Environments,
    <App>.McpServers,
    <App>Spex.Fixtures,
    <App>Web
  ]
```

If a new spec needs something outside those deps, the rule is not
"add it to deps." The rule is: either (a) add a narrow function to
`<App>Spex.Fixtures`, or (b) find a way to drive the state
through the UI / hook surface instead.

## The Fixtures bridge

`<App>Spex.Fixtures` (`test/support/fixtures/<app>_spex_fixtures.ex`) is
the *only* module that deps on `<App>` and `<App>Test`. It
re-exports a curated set of fixture functions.

**Rule of thumb:** Fixtures exposes state that **originates
server-side and syncs into the local app** — users, accounts,
top-level entities. Local-only state (configuration tied to a
specific UI flow, derived state produced by a sync/analyzer step)
should be established by driving the real flow, not by calling a
fixture.

### Typical surface

| Category | Function |
|---|---|
| Sandbox | `setup_sandbox/1` |
| Session | `generate_user_session_token/1`, etc. |
| Users | `user_fixture/1`, `user_scope_fixture/{0,1,2,3}` |
| Accounts | `account_fixture/1`, `account_with_owner_fixture/2` |
| Top-level entities | `project_fixture/2` (or app's equivalent) |

Project specifics — full inventory, types, and any project-specific
fixtures — belong in the project's own BDD spec plan
(`.code_my_spec/knowledge/bdd/spex/`), not here.

### When to add to Fixtures

Before adding a function, ask:

1. Can the state be produced by driving the LiveView? (Preferred.)
2. Can it be produced by writing a file and letting sync run?
3. Is this state that server-side sync *would* populate in production?

If (1) or (2) works, use it. (3) is the justification for a new fixture
function. Adding a fixture for state the user would create locally
through the UI is a boundary violation disguised as a fixture.

## What a `then_` is allowed to read

- **Rendered HTML** — `render(view)`, `has_element?/2`,
  `element/2 |> render()`.
- **HTTP response body** — `json_response/2`, `response/2`, `redirected_to/2`.
- **Memfs state** — `Environments.read_file/2`,
  `Environments.file_exists?/2`, `Environments.list_directory/2`.
  (Only when the user-visible effect *is* a file on disk; e.g. "the
  spec generator wrote a spec file.")

What a `then_` is **not** allowed to do:

- Call context functions (`<App>.SomeContext.list_*`,
  `<App>.OtherContext.get_*`, etc.).
- Query `Repo` directly.
- Read from a fixture's underlying schema to prove the outcome.

The contract is: a `then_` step proves what the user sees, not that
a row exists.

## Anti-pattern: seeding server-side state that the agent should have produced

When a scenario's ostensible purpose is to test a downstream
decision, it is tempting to fast-forward by seeding the upstream
artifact directly. Example:

```elixir
given_ "an exunit failure exists on an untouched component", context do
  Fixtures.problem_fixture(context.scope, %{
    source: "exunit", source_type: :test, ...,
    component_id: context.component.id
  })
  {:ok, context}
end
```

This seeds a row directly. The scenario still passes, but it has
stopped being an acceptance test — it's a unit test for the
downstream decision dressed up in Given-When-Then. If the upstream
producer were broken such that it never persisted that row at all,
this spec would still pass. That's the cost.

When to accept the shortcut: if (a) the upstream production is
covered by a separate spec that *does* go end-to-end, and (b) the
scenario under test is about the downstream decision, not the
upstream production. Even then, leave a module-level comment that
calls the shortcut out explicitly. The shortcut is a known debt,
not a stealth change to the contract.

## Anti-pattern: direct DB reads in `then_`

```elixir
# WRONG
then_ "the configuration is saved", context do
  config = <App>.SomeContext.get!(context.project.id)
  assert config.some_field == false
  :ok
end
```

This proves the DB row changed, not that the user's action had the
intended effect. Re-mount the LiveView (or assert against the form
state on the live view already in the context) and check what the
user sees.

```elixir
# RIGHT
then_ "the field renders unchecked on reload", context do
  {:ok, config_live, _html} =
    live(context.conn, ~p"/projects/#{context.project.name}/configuration")

  refute has_element?(config_live, "[data-test='some-field']:checked")
  :ok
end
```
