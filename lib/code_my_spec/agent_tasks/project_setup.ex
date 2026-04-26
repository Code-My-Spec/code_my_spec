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
  alias CodeMySpec.AgentTasks.Setup.Context

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

  @doc """
  Returns the ordered list of setup step modules.

  Override via `Application.put_env(:code_my_spec, :project_setup_steps, [MyStub | ...])`
  for test-time injection. Production code should not set this key.
  """
  def setup_steps do
    Application.get_env(:code_my_spec, :project_setup_steps, @setup_steps)
  end

  @doc "Find a setup step module by its derived ID."
  def find_step(id) do
    Enum.find(setup_steps(), fn mod -> step_id(mod) == id end)
  end

  @doc "Derive a URL-friendly ID from a step module name."
  def step_id(mod), do: mod |> Module.split() |> List.last() |> Macro.underscore()

  @doc "Derive a human-readable name from a step module name."
  def step_name(mod) do
    mod |> Module.split() |> List.last() |> Macro.underscore() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc """
  Generate setup instructions with inline prompts for incomplete steps.

  Evaluates each step (against a single preloaded `Setup.Context`), shows
  completed steps as checked off, and inlines the full command prompt for
  each incomplete step. One prompt, one agent.

  Returns `{:error, reason}` if any incomplete step's `command/2` returns
  an error — the caller (LiveView, agent harness) must see it, not swallow it.
  """
  @spec command(term(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, _task) do
    ctx = Context.load(scope)

    with {:ok, steps} <- build_step_status(scope, ctx) do
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
  end

  defp build_step_status(scope, ctx) do
    setup_steps()
    |> Enum.reduce_while({:ok, []}, fn mod, {:ok, acc} ->
      accumulate_step(mod, scope, ctx, acc)
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      {:error, _} = err -> err
    end
  end

  defp accumulate_step(mod, scope, ctx, acc) do
    if step_done?(mod, ctx) do
      {:cont, {:ok, [%{name: step_name(mod), done: true, prompt: nil} | acc]}}
    else
      case mod.command(scope, %{}) do
        {:ok, prompt} ->
          {:cont, {:ok, [%{name: step_name(mod), done: false, prompt: prompt} | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, {:unexpected_command_return, mod, other}}}
      end
    end
  end

  defp step_done?(mod, ctx), do: mod.check(ctx) == :valid

  @doc """
  Evaluate setup completion by running each step's pure `check/1` against a
  single preloaded `Setup.Context`.

  Returns:
  - `{:ok, :valid}` if all steps pass
  - `{:ok, :invalid, feedback}` listing incomplete steps

  Pure observation — no side effects. One DB query (setup-role files) plus one
  targeted query for the web Application file. Zero filesystem reads on the
  hot path; ProjectStructure is the only step that stats the filesystem and
  only when its directories haven't been created yet.
  """
  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()} | {:error, term()}
  def evaluate(scope, _task, _opts \\ []) do
    ctx = Context.load(scope)

    incomplete = Enum.reject(setup_steps(), fn mod -> mod.check(ctx) == :valid end)

    if incomplete == [] do
      {:ok, :valid}
    else
      feedback = Enum.map_join(incomplete, "\n", fn mod -> "- [ ] #{step_name(mod)}" end)

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
