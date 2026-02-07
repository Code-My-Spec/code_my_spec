defmodule CodeMySpec.Projects.Lifecycle do
  @moduledoc """
  Project lifecycle evaluation for agentic mode.

  Checks BDD spec status and determines next action for the agent.
  When agentic_mode is enabled on a project, this module runs as part of
  the Stop hook chain to keep the agent working until all stories are complete.
  """

  require Logger

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.Environments
  alias CodeMySpec.Projects

  @type evaluation_result ::
          {:ok, :complete}
          | {:ok, :specs_failing, [Spex.Failure.t()]}
          | {:ok, :next_story, CodeMySpec.Stories.Story.t()}
          | {:error, term()}

  @doc """
  Evaluate project state for agentic mode.

  Runs BDD specs and checks for incomplete stories.

  ## Returns

  - `{:ok, :complete}` - All stories done, specs passing
  - `{:ok, :specs_failing, failures}` - BDD specs failing
  - `{:ok, :next_story, story}` - Specs passing, next story needs BDD specs
  - `{:error, reason}` - Error running evaluation
  """
  @spec evaluate(CodeMySpec.Users.Scope.t(), keyword()) :: evaluation_result()
  def evaluate(scope, opts \\ []) do
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())

    Logger.info("[Lifecycle] Evaluating project lifecycle, working_dir: #{working_dir}")

    case run_bdd_specs(working_dir) do
      {:ok, []} ->
        Logger.info("[Lifecycle] All BDD specs passing, checking for incomplete stories")
        check_for_incomplete_stories(scope, working_dir)

      {:ok, failures} ->
        Logger.info("[Lifecycle] BDD specs failing: #{length(failures)} failure(s)")
        {:ok, :specs_failing, failures}

      {:error, reason} ->
        Logger.error("[Lifecycle] Error running BDD specs: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Format evaluation result as a hook decision map.

  Returns an empty map (allow stop) or a map with decision: "block" and reason.
  """
  @spec format_hook_result(evaluation_result(), CodeMySpec.Users.Scope.t()) :: map()
  def format_hook_result({:ok, :complete}, scope) do
    Logger.info("[Lifecycle] Project complete, disabling agentic mode")

    case Projects.update_project(scope, scope.active_project, %{agentic_mode: false}) do
      {:ok, _project} ->
        Logger.info("[Lifecycle] Agentic mode disabled successfully")

      {:error, reason} ->
        Logger.warning("[Lifecycle] Failed to disable agentic mode: #{inspect(reason)}")
    end

    %{}
  end

  def format_hook_result({:ok, :specs_failing, failures}, _scope) do
    %{"decision" => "block", "reason" => format_failures(failures)}
  end

  def format_hook_result({:ok, :next_story, story}, _scope) do
    %{
      "decision" => "block",
      "reason" => """
      All BDD specs are passing!

      Next story needs BDD specs:
      - Story ##{story.id}: #{story.title}
      - Priority: #{story.priority}

      Invoke /write-bdd-specs to create BDD specs for this story.
      """
    }
  end

  def format_hook_result({:error, reason}, _scope) do
    %{"decision" => "block", "reason" => "Error: #{inspect(reason)}"}
  end

  # Private functions

  defp run_bdd_specs(working_dir) do
    case Spex.execute([], project_root: working_dir, quiet: true) do
      {:ok, failures, _exit_code} -> {:ok, failures}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_for_incomplete_stories(scope, working_dir) do
    {:ok, env} = Environments.create(:cli, working_dir: working_dir)

    case BddSpecs.get_next_incomplete_story(env, scope) do
      nil ->
        Logger.info("[Lifecycle] No incomplete stories found, project is complete")
        {:ok, :complete}

      story ->
        Logger.info("[Lifecycle] Found incomplete story: #{story.id} - #{story.title}")
        {:ok, :next_story, story}
    end
  end

  defp format_failures(failures) do
    failure_text = Enum.map_join(failures, "\n\n", &format_failure/1)

    """
    BDD specs are failing. Fix these failures before proceeding:

    #{failure_text}

    Analyze the failures and implement the necessary context/components to make specs pass.
    """
  end

  defp format_failure(failure) do
    steps_text = format_steps(failure.steps)
    error_text = if failure.error, do: failure.error.message, else: "Unknown error"

    """
    ## #{failure.spex} - #{failure.scenario}

    #{steps_text}

    Error: #{error_text}
    """
  end

  defp format_steps(steps) do
    Enum.map_join(steps, "\n", fn step ->
      icon = if step.status == "passed", do: "✓", else: "✗"
      "#{icon} #{step.type}: #{step.description}"
    end)
  end
end
