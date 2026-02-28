defmodule CodeMySpec.AgentTasks.ContextComponentSpecs do
  @moduledoc """
  Container task for the `children_designs` requirement.

  `command/3` returns only the static instructional prompt — child collection
  and prompt file generation are handled by the top-level orchestrator via
  each child task's `orchestrate/3`.

  `evaluate/3` checks whether all children still have actionable spec work.
  """

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
end
