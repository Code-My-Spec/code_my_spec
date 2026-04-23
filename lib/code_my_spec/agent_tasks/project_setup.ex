defmodule CodeMySpec.AgentTasks.ProjectSetup do
  @moduledoc """
  Agent task that guides developers through complete Phoenix project setup for CodeMySpec integration.

  Generates comprehensive setup instructions and evaluates current setup state by checking
  prerequisites, project structure, dependencies, and .code_my_spec/ directory configuration.
  Designed to be run from a target directory that will become (or already is) a Phoenix project root.

  The agent approach (vs running the ScriptGenerator script directly) allows picking up setup
  from any point and provides flexibility for the agent to adapt to different starting states.
  """

  def orchestrate(node) do
    "Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  alias CodeMySpec.AgentTasks.Setup

  @setup_steps [
    Setup.ApplicationInWeb,
    Setup.CodemyspecDeps,
    Setup.Compilers,
    Setup.SpexConfig,
    Setup.TestBoundaries,
    Setup.TestSupportNamespace,
    Setup.SpexCase,
    Setup.ProjectStructure,
    Setup.IgnoredPaths,
    Setup.AgentsMd,
    Setup.Rules,
    Setup.CredoChecks,
    Setup.ClaudeMd
  ]

  @doc "Returns the ordered list of setup step modules."
  def setup_steps, do: @setup_steps

  @doc "Find a setup step module by its derived ID."
  def find_step(id) do
    Enum.find(@setup_steps, fn mod -> step_id(mod) == id end)
  end

  @doc "Derive a URL-friendly ID from a step module name."
  def step_id(mod), do: mod |> Module.split() |> List.last() |> Macro.underscore()

  @doc "Derive a human-readable name from a step module name."
  def step_name(mod) do
    mod |> Module.split() |> List.last() |> Macro.underscore() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc """
  Generate setup instructions with inline prompts for incomplete steps.

  Evaluates each step, shows completed steps as checked off, and inlines
  the full command prompt for each incomplete step. One prompt, one agent.
  """
  @spec command(term(), map()) :: {:ok, String.t()}
  def command(scope, _task) do
    steps = build_step_status(scope)
    done = Enum.count(steps, & &1.done)
    total = length(steps)

    checklist =
      Enum.map_join(steps, "\n\n", fn step ->
        if step.done do
          "- [x] **#{step.name}**"
        else
          "- [ ] **#{step.name}**\n\n#{step.prompt}"
        end
      end)

    {:ok, """
    # Project Setup (#{done}/#{total})

    Configure this Phoenix project for CodeMySpec integration.
    Complete all unchecked steps below. Order does not matter.

    #{checklist}

    When all steps are complete, use `evaluate_task` to validate.
    """}
  end

  defp build_step_status(scope) do
    Enum.map(@setup_steps, fn mod ->
      done =
        case mod.evaluate(scope, %{}) do
          {:ok, :valid} -> true
          _ -> false
        end

      prompt = if done, do: nil, else: step_prompt(mod, scope)

      %{name: step_name(mod), done: done, prompt: prompt}
    end)
  end

  defp step_prompt(mod, scope) do
    case mod.command(scope, %{}) do
      {:ok, text} -> text
      _ -> "Run #{step_name(mod)}"
    end
  end

  @doc """
  Evaluate setup completion by running each step's evaluate.

  Returns:
  - `{:ok, :valid}` if all steps pass
  - `{:ok, :invalid, feedback}` listing incomplete steps
  """
  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, _task, _opts \\ []) do
    steps = build_step_status(scope)
    incomplete = Enum.reject(steps, & &1.done)

    if incomplete == [] do
      {:ok, :valid}
    else
      feedback =
        incomplete
        |> Enum.map_join("\n", fn step -> "- [ ] #{step.name}" end)

      {:ok, :invalid, "Setup incomplete (#{length(incomplete)} steps remaining):\n\n#{feedback}"}
    end
  end

  @doc "Check for RequirementCalculator."
  @spec check(term(), term()) :: {boolean(), map()}
  def check(scope, _entity) do
    case evaluate(scope, %{}) do
      {:ok, :valid} -> {true, %{status: "All setup steps complete"}}
      {:ok, :invalid, _} -> {false, %{reason: "Setup steps incomplete"}}
      _ -> {false, %{reason: "Setup evaluation failed"}}
    end
  end

end
