# Spex Boundary Ready — Install Workflow

The `spex_boundary_ready` task installs the four pieces of project-local
infrastructure that protect the BDD spec boundary:

1. Framework Credo checks (universal function-level denies and the
   `no_direct_send_in_spex` check).
2. A project-local Credo check that fills in the whole-module deny list
   — stdlib bypasses (`File`, `Port`, `:file`) plus internal app
   contexts the spec boundary must not reach.
3. A curated fixtures bridge re-exporting the minimum set of
   server-state seeders specs may use. **It is its own top-level
   Boundary**, separate from the spec boundary — see step 3.
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
  what the Fixtures bridge is for, including the top-level-Boundary
  arrangement.
- `priv/knowledge/bdd/spex/writing_a_spex.md` — file layout, DSL,
  setup template.
- `.code_my_spec/architecture/proposal.md` — the architecture proposal
  the agent mines for project-specific denies in step 2.

## Step 1 — install the framework Credo checks

Call the `install_credo_checks` MCP tool. It copies
`spex_denied_calls.ex` and `no_direct_send_in_spex.ex` from the
harness's `priv/credo_checks/` into
`.code_my_spec/credo_checks/framework/`. These files are the floor:

- `no_direct_send_in_spex` — denies direct `send/2` so specs can't
  bypass PubSub through the real Phoenix surface.
- `spex_denied_calls` (framework template) — denies universal
  function-level bypasses: `System.cmd/shell/halt/...`, `Code.eval_*`,
  `Code.compile_*`, `:os.cmd`, `Kernel.apply`.

**The framework template ships with empty whole-module deny lists by
design.** Stdlib whole-module denies (`File`, `Port`, `:file`) and
project-context denies go in the project-local check in step 2.

Do not edit the framework files. The harness's `install_credo_checks`
is idempotent and never overwrites them after the first install, but
treat them as synced output.

After the tool runs, read
`.code_my_spec/credo_checks/framework/spex_denied_calls.ex` so you
can mirror its AST traversal in the project-local check.

## Step 2 — write the project-local Credo check

This check carries the whole-module deny list — both the universal
stdlib bypasses and the project's internal contexts.

Read `.code_my_spec/architecture/proposal.md`. Identify internal
namespaces specs must NOT reach.

**Baseline (every project should include these):**

- `File`, `:file` — specs run against the in-memory env; real-disk
  reads silently bypass it.
- `Port` — ports talk to external programs; use cassettes for
  CLI-driven steps.

**Project-specific (mine from the architecture proposal):**

- `<App>.Repo` — direct DB access bypasses the public surface.
- Every `<App>` context that the spec boundary does NOT dep on. The
  spec boundary's deps live in `test/spex/<app>_spex.ex` — anything
  outside that list belongs on the deny list.

**Do NOT deny** — schemas and the public-surface modules (LiveView
modules, MCP tool modules, controllers). Those are the legal
surfaces.

Write the check to
`.code_my_spec/credo_checks/local/<app>_spex_denies.ex`, modelled on
the framework `spex_denied_calls.ex`. Use:

- A fresh `id:` (e.g. `"<APP>0001"` — first six uppercase letters of
  the app name + numeric suffix).
- `base_priority: :high`.
- A **distinct module name** from the framework one
  (e.g. `<App>.Check.Warning.<App>SpexDenies`) so the two checks
  coexist.
- Whole-module denies only. Function-level denies are already in the
  framework check.

Also drop a `local/checks.exs` next to the module:

```elixir
# Project-local Credo checks — maintained by the project, not synced.
[
  {<App>.Check.Warning.<App>SpexDenies, []}
]
```

Wire it into `.credo.exs` by appending the eval next to the framework
one — the convention is:

```elixir
| if(File.exists?(".code_my_spec/credo_checks/framework/checks.exs"),
    do: elem(Code.eval_file(".code_my_spec/credo_checks/framework/checks.exs"), 0),
    else: [])
  ++
  if(File.exists?(".code_my_spec/credo_checks/local/checks.exs"),
    do: elem(Code.eval_file(".code_my_spec/credo_checks/local/checks.exs"), 0),
    else: [])
```

## Step 3 — scaffold the fixtures bridge

The fixtures bridge is **its own top-level Boundary**, not a member of
the spec boundary. This is load-bearing:

- The bridge needs to dep on `<App>` (and any `<App>Test` shared
  fixtures) so it can reach across into app internals.
- The spec boundary (`<App>Spex`) must NOT dep on `<App>` — that would
  defeat the seal.
- The bridge's solution: declare `use Boundary, top_level?: true,
  deps: [<App>, <App>.Environments]`. The spec boundary then deps on
  the bridge module, not on `<App>` — so the wide deps don't leak.

Create `test/support/fixtures/<app>_spex_fixtures.ex`:

```elixir
defmodule <App>Spex.Fixtures do
  @moduledoc """
  Curated bridge from BDD specs into in-app state.

  The only module that may dep on `<App>` from inside the spex test
  tree. Declared as its own top-level Boundary so the spec boundary
  can dep on it without inheriting `<App>`'s deps.
  """

  use Boundary, top_level?: true, deps: [<App>, <App>.Environments]

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
- At least one project-local Credo check (`*.ex`) at
  `.code_my_spec/credo_checks/local/`.
- The fixtures bridge at `test/support/fixtures/<app>_spex_fixtures.ex`.
- At least one `.md` in `.code_my_spec/knowledge/bdd/spex/`.

Missing pieces produce specific feedback. The agent in the next session
sees only the prompt — not your in-flight reasoning — so do the
planning work this turn.
