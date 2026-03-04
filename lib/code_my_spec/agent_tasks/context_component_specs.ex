defmodule CodeMySpec.AgentTasks.ContextComponentSpecs do
  @moduledoc """
  Container task for the `children_designs` requirement.

  `command/3` returns only the static instructional prompt — child collection
  and prompt file generation are handled by the top-level orchestrator via
  each child task's `orchestrate/3`.

  `evaluate/3` checks whether all children have their `spec_file` requirement
  satisfied.

  `orchestrate/3` and `orchestrate_evaluate/3` delegate to
  `ProjectCoordinator.default_orchestrate/4` so this module can appear as a
  `task_module` in the `:children` dispatch loop (nested contexts).
  """

  alias CodeMySpec.Components
  alias CodeMySpec.ProjectCoordinator

  def command(_scope, session, _opts \\ []) do
    %{component: context} = session

    {:ok, """
    # Child Component Designs: #{context.name}

    Design specifications for the child components listed below.
    You can invoke multiple subagents in parallel — child specs are independent.

    ## Subagent Usage

    For each component, invoke `@"CodeMySpec:spec-writer (agent)"` to:
    1. Read the prompt file
    2. Follow the instructions to create the specification
    3. Write the spec file to the specified location

    ## Completion

    Once all subagents have completed, **stop the session** so the hook can validate.
    Do not continue to the next phase — the hook will advance you.
    """}
  end

  def evaluate(scope, session, _opts \\ []) do
    %{component: context} = session
    children = Components.list_child_components(scope, context.id)

    missing =
      Enum.reject(children, fn child ->
        (child.requirements || [])
        |> Enum.any?(fn r -> r.name == "spec_file" and r.satisfied end)
      end)

    if Enum.empty?(missing) do
      {:ok, :valid}
    else
      names = Enum.map_join(missing, "\n", fn c -> "- #{c.module_name}" end)
      {:ok, :invalid, "Children still need specs:\n#{names}"}
    end
  end

  def orchestrate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate(__MODULE__, scope, session, opts)
  end

  def orchestrate_evaluate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate_evaluate(__MODULE__, scope, session, opts)
  end
end
