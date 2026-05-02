defmodule CodeMySpec.AgentTasks.SpexBoundaryReady do
  @moduledoc """
  Agent task for the `spex_boundary_ready` project requirement.

  Drives the agent through installing the BDD-spec boundary protections
  for this project:

    1. Run `install_credo_checks` to copy the framework Credo checks
       into `.code_my_spec/credo_checks/framework/` (denies stdlib calls
       that would let a spec cheat past the in-memory env, plus
       `no_direct_send_in_spex` which is universal for Phoenix LiveView
       projects).
    2. Read `architecture/proposal.md` and add a project-local Credo
       check to `.code_my_spec/credo_checks/local/` that denies any
       internal namespaces specs must not reach (Repo, internal contexts
       behind a public surface, etc.).
    3. Scaffold `test/support/fixtures/<app>_spex_fixtures.ex` — the
       curated bridge that re-exports the minimum set of fixture
       functions a spec needs to seed server-originated state.

  Validation is existence-only (see `Requirements.SpexBoundaryChecker`).
  Quality of the local check + fixture selection lives in the prompt.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.{Environments, Paths}
  alias CodeMySpec.Requirements.{CheckerResult, SpexBoundaryChecker}

  def orchestrate(node) do
    "Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  @spec command(CodeMySpec.Users.Scope.t(), map()) :: {:ok, String.t()}
  def command(%{environment: nil}, _task) do
    {:ok,
     "# Spex Boundary Ready\n\nProject environment is not available yet — finish project setup so the working directory is bound, then re-open this requirement."}
  end

  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "your_app"
    app_module = camelize(app_name)
    proposal_path = Path.join(Paths.architecture_dir(), "proposal.md")
    proposal_present? = Environments.file_exists?(env, proposal_path) == true

    {:ok, build_prompt(app_name, app_module, proposal_path, proposal_present?)}
  end

  @spec evaluate(CodeMySpec.Users.Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    scope |> SpexBoundaryChecker.complete?(nil) |> CheckerResult.to_evaluation()
  end

  defp build_prompt(app_name, app_module, proposal_path, proposal_present?) do
    fixtures_path = "test/support/fixtures/#{app_name}_spex_fixtures.ex"
    framework_dir = Paths.credo_checks_framework_dir()
    local_dir = Paths.credo_checks_local_dir()

    """
    # Spex Boundary Ready

    The BDD spec suite (`mix spex`) runs in a sealed boundary that
    prevents specs from reaching past the public interaction surfaces
    (LiveView, HTTP hooks, MCP tools). Four things have to be on disk
    before any story can write specs:

    1. Framework Credo checks copied in.
    2. A project-local Credo check denying internal namespaces specs
       must not reach.
    3. A curated fixtures bridge module — the only legal door from a
       spec into in-app state.
    4. A project-tailored BDD spec plan complementing the generic
       framework BDD docs.

    Validation only checks file existence. Use this turn to do the
    planning work in the prompt; the next turn won't see it.

    ## Required Reading

    Read these before writing anything. Do not skip:

    - `.code_my_spec/framework/bdd/spex/philosophy.md` — why specs are sealed.
    - `.code_my_spec/framework/bdd/spex/boundaries.md` — what a spec may
      call and what the Fixtures bridge is for.
    - `.code_my_spec/framework/bdd/spex/writing_a_spex.md` — file layout,
      DSL, setup template.
    - `#{proposal_path}` — the architecture proposal you'll mine for
      project-specific denies. #{proposal_marker(proposal_present?)}

    ## Step 1: Install the Framework Credo Checks

    Call the `install_credo_checks` MCP tool. It copies
    `spex_denied_calls.ex` and `no_direct_send_in_spex.ex` from the
    harness's `priv/credo_checks/` into `#{framework_dir}/`. These files
    are the floor: stdlib denies (File / Port / System.cmd / Code.eval /
    Kernel.apply / :os.cmd) plus a deny on direct `send/2` so specs
    can't bypass PubSub through the real Phoenix surface.

    Do not edit the framework files. Project-specific denies go in
    step 2.

    After the tool runs, read `#{framework_dir}/spex_denied_calls.ex`
    so you can model the project-local check on it.

    ## Step 2: Write a Project-Local Credo Check

    Read `#{proposal_path}`. Identify internal namespaces that specs
    must NOT reach. Typical candidates:

    - `#{app_module}.Repo` — direct DB access bypasses the public
      surface.
    - Internal contexts that exist behind a public LiveView / MCP
      surface. The user's surface is the LiveView; calling the context
      directly from a spec would bypass auth, validation, broadcasts.
    - Any module the architecture explicitly marks "internal" or
      "private."

    Schemas and the public-surface modules (LiveView modules, MCP tool
    modules, controllers) should NOT be denied — those are the legal
    surfaces.

    Write the check to `#{local_dir}/<short_name>_spex_denies.ex`,
    modelled on `#{framework_dir}/spex_denied_calls.ex`. Use a fresh
    `id:` (e.g. `"#{check_id_prefix(app_name)}0001"`) and
    `base_priority: :high`. Limit it to whole-module denies — function-
    level denies are rarely worth the maintenance.

    ## Step 3: Scaffold the Fixtures Bridge

    Create `#{fixtures_path}`:

    ```elixir
    defmodule #{app_module}Spex.Fixtures do
      @moduledoc \"\"\"
      Curated bridge from BDD specs into in-app state.

      The only module that may dep on `#{app_module}` and `#{app_module}Test`
      from inside the spex boundary. Re-exports a minimum set of
      fixture functions for state that originates server-side
      (users, accounts, sessions). State the user creates locally
      through the UI should be driven through the LiveView, not
      seeded here.
      \"\"\"

      use Boundary, deps: [#{app_module}, #{app_module}Test]

      # --- Sandbox ---
      defdelegate setup_sandbox(tags), to: #{app_module}Test.DataCase

      # --- Add re-exports below as specs need them. Keep the list
      # small; every export here is a sanctioned shortcut past the
      # UI. ---
    end
    ```

    Decide which fixture functions the project actually needs *now*
    based on the architecture (users, accounts, sessions are typical).
    Re-export them with `defdelegate`. Leave a one-line comment above
    any function whose addition you weren't sure about — the next
    reviewer can prune it.

    ## Step 4: Write the Project BDD Spec Plan

    Write a project-specific BDD spec plan to
    `.code_my_spec/knowledge/bdd/spex/index.md` (filename is your call;
    the checker just requires at least one `.md` in that directory).

    The plan should answer "how does BDD work in *this* project" — the
    framework docs at `.code_my_spec/framework/bdd/spex/` cover the generic
    side. Tailor:

    - Which surfaces are the public ones a spec is allowed to drive
      (LiveView routes, HTTP hook endpoints, MCP tool modules) — name
      the modules concretely from the architecture.
    - The fixture inventory that's allowed in `given_` — list every
      function on `#{app_module}Spex.Fixtures` and what state each
      represents.
    - Legal observable surfaces in `then_` — concrete examples for this
      project's response shapes.
    - Project-specific anti-patterns to avoid (e.g. "do not seed
      `#{app_module}.<InternalContext>` rows in `given_` — the user
      action that produces them is X").

    ## Step 5: Stop

    Stop the session. Validation will check that the two framework
    files, the fixtures bridge file, and at least one `.md` in the
    project BDD plan directory all exist. If a piece is missing,
    you'll get feedback pointing at the gap.
    """
  end

  defp proposal_marker(true), do: "Present."

  defp proposal_marker(false),
    do: "**MISSING — stop and resolve `architecture_designed` first.**"

  defp camelize(name) do
    name |> String.split("_") |> Enum.map_join("", &String.capitalize/1)
  end

  defp check_id_prefix(app_name) do
    app_name
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
    |> String.slice(0, 6)
  end
end
