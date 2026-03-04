defmodule CodeMySpec.AgentTasks.ContextImplementation do
  @moduledoc """
  Container task for the `children_implementations` requirement.

  `command/3` returns only the static instructional prompt — child collection
  and prompt file generation are handled by the top-level orchestrator via
  each child task's `orchestrate/3`.

  `evaluate/3` checks whether all children have their implementation
  requirements satisfied (implementation_file, test_file, tests_passing).

  `orchestrate/3` and `orchestrate_evaluate/3` delegate to
  `ProjectCoordinator.default_orchestrate/4` so this module can appear as a
  `task_module` in the `:children` dispatch loop (nested contexts).
  """

  alias CodeMySpec.Components
  alias CodeMySpec.ProjectCoordinator

  @implementation_reqs ["implementation_file", "test_file", "tests_passing"]

  def command(_scope, session, _opts \\ []) do
    %{component: context} = session

    {:ok, """
    # Child Implementation: #{context.name}

    Implement the child components listed below. Work in dependency order:

    - **Schemas** first (no dependencies)
    - **Repositories** next (depend on schemas)
    - **Services/GenServers** (depend on repositories and schemas)
    - **LiveComponents** before LiveViews (shared components first)
    - **LiveViews** last (compose and use shared components)

    For each component: write tests first, then implement code.
    You can parallelize within a layer (e.g., multiple schemas at once).

    ## Subagent Usage

    - For test prompts: `@"CodeMySpec:test-writer (agent)"`
    - For code prompts: `@"CodeMySpec:code-writer (agent)"`

    ## Completion

    Once all subagents have completed, **stop the session** so the hook can validate.
    Do not continue to the next phase — the hook will advance you.
    """}
  end

  def evaluate(scope, session, _opts \\ []) do
    %{component: context} = session
    children = Components.list_child_components(scope, context.id)

    missing = Enum.reject(children, &implementation_complete?/1)

    if Enum.empty?(missing) do
      {:ok, :valid}
    else
      names = Enum.map_join(missing, "\n", fn c -> "- #{c.module_name}" end)
      {:ok, :invalid, "Children still need implementation:\n#{names}"}
    end
  end

  def orchestrate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate(__MODULE__, scope, session, opts)
  end

  def orchestrate_evaluate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate_evaluate(__MODULE__, scope, session, opts)
  end

  defp implementation_complete?(child) do
    reqs = child.requirements || []

    Enum.all?(@implementation_reqs, fn req_name ->
      Enum.any?(reqs, fn r -> r.name == req_name and r.satisfied end)
    end)
  end
end
