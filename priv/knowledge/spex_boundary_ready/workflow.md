# Spex Boundary Ready — Install Workflow

The `spex_boundary_ready` task installs the four pieces of project-local
infrastructure that protect the BDD spec boundary:

1. Framework Credo checks (stdlib denies + no_direct_send).
2. A project-local Credo check denying internal namespaces specs
   must not reach.
3. A curated fixtures bridge re-exporting the minimum set of
   server-state seeders specs may use.
4. A project-tailored BDD spec plan complementing the generic
   framework docs.

Validation is existence-only — the requirement passes once all four
artifacts are on disk. Quality lives in the prompt and in this doc.

## Required reading before installing

Read these before writing anything. The framework docs explain *what*
the boundary is and *why*; this workflow doc covers the install
procedure.

- `priv/knowledge/bdd/spex/philosophy.md` — why specs are sealed.
- `priv/knowledge/bdd/spex/boundaries.md` — what a spec may call and
  what the Fixtures bridge is for.
- `priv/knowledge/bdd/spex/writing_a_spex.md` — file layout, DSL,
  setup template.
- `.code_my_spec/architecture/proposal.md` — the architecture proposal
  the agent mines for project-specific denies in step 2.

## Step 1 — install the framework Credo checks

Call the `install_credo_checks` MCP tool. It copies
`spex_denied_calls.ex` and `no_direct_send_in_spex.ex` from the
harness's `priv/credo_checks/` into
`.code_my_spec/credo_checks/framework/`. These files are the floor:

- stdlib denies — `File`, `Port`, `System.cmd`, `Code.eval`,
  `Kernel.apply`, `:os.cmd`
- a deny on direct `send/2` so specs can't bypass PubSub through the
  real Phoenix surface

Do not edit the framework files. Project-specific denies go in step 2.

After the tool runs, read
`.code_my_spec/credo_checks/framework/spex_denied_calls.ex` so you
can model the project-local check on its structure.

## Step 2 — write a project-local Credo check

Read `.code_my_spec/architecture/proposal.md`. Identify internal
namespaces that specs must NOT reach.

**Typical candidates to deny:**

- `<App>.Repo` — direct DB access bypasses the public surface.
- Internal contexts that exist behind a public LiveView / MCP
  surface. The user's surface is the LiveView; calling the context
  directly from a spec bypasses auth, validation, broadcasts.
- Any module the architecture explicitly marks "internal" or
  "private."

**Do NOT deny** — schemas and the public-surface modules (LiveView
modules, MCP tool modules, controllers). Those are the legal
surfaces.

Write the check to
`.code_my_spec/credo_checks/local/<short_name>_spex_denies.ex`,
modelled on the framework `spex_denied_calls.ex`. Use:

- A fresh `id:` (e.g. `"<APP>0001"` — first six uppercase letters of
  the app name + numeric suffix).
- `base_priority: :high`.
- Whole-module denies only. Function-level denies are rarely worth
  the maintenance.

## Step 3 — scaffold the fixtures bridge

Create `test/support/fixtures/<app>_spex_fixtures.ex`:

```elixir
defmodule <App>Spex.Fixtures do
  @moduledoc """
  Curated bridge from BDD specs into in-app state.

  The only module that may dep on `<App>` and `<App>Test` from inside
  the spex boundary. Re-exports a minimum set of fixture functions
  for state that originates server-side (users, accounts, sessions).
  State the user creates locally through the UI should be driven
  through the LiveView, not seeded here.
  """

  use Boundary, deps: [<App>, <App>Test]

  # --- Sandbox ---
  defdelegate setup_sandbox(tags), to: <App>Test.DataCase

  # --- Add re-exports below as specs need them. Keep the list
  # small; every export here is a sanctioned shortcut past the
  # UI. ---
end
```

Decide which fixture functions the project actually needs *now* based
on the architecture (users, accounts, sessions are typical).
Re-export them with `defdelegate`. Leave a one-line comment above any
function whose addition is uncertain — the next reviewer can prune it.

## Step 4 — write the project BDD spec plan

Write a project-specific BDD spec plan to
`.code_my_spec/knowledge/bdd/spex/index.md` (filename is your call;
the checker just requires at least one `.md` in that directory).

The plan answers "how does BDD work in *this* project" — the framework
docs cover the generic side. Tailor:

- **Public surfaces.** Which surfaces is a spec allowed to drive
  (LiveView routes, HTTP hook endpoints, MCP tool modules)? Name the
  modules concretely from the architecture.
- **Fixture inventory.** Every function on `<App>Spex.Fixtures` and
  what state each represents.
- **Legal observable surfaces in `then_`.** Concrete examples for
  this project's response shapes (LiveView render assertion, JSON
  response shape, MCP tool result tuple, etc.).
- **Project-specific anti-patterns.** "Do not seed
  `<App>.<InternalContext>` rows in `given_` — the user action that
  produces them is X."

## Step 5 — stop

Stop the session. Validation checks:

- The two framework Credo check files at
  `.code_my_spec/credo_checks/framework/`.
- At least one project-local Credo check at
  `.code_my_spec/credo_checks/local/`.
- The fixtures bridge at `test/support/fixtures/<app>_spex_fixtures.ex`.
- At least one `.md` in `.code_my_spec/knowledge/bdd/spex/`.

Missing pieces produce specific feedback. The agent in the next session
sees only the prompt — not your in-flight reasoning — so do the
planning work this turn.
