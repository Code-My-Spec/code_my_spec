defmodule CodeMySpec.AgentTasks.FixBddSpecs do
  @moduledoc """
  Agent task for fixing failing BDD specifications.

  Reads spex failures from the Problems table, scopes them to the task's story
  (or the whole project when the task has none), keeps only failures whose
  story's component has a satisfied `implementation_file` requirement, and
  builds a prompt instructing the agent to fix the implementation so the specs
  pass.

  - `command/2` — reads spex problems, builds the fix prompt
  - `evaluate/2`, `evaluate/3` — the ready-for-QA certification (`ReadyForQa`)
  """

  def analyzers, do: [:spex_stale]

  def dispatch(_node) do
    "Fix the failing BDD spec files for a story — diagnose the failure (test " <>
      "assertion, missing fixture, surface mismatch), edit the spec or the " <>
      "underlying implementation, and re-run `mix spex` until green. Use " <>
      "when a story's BDD spec files exist but one or more criteria fail."
  end

  alias CodeMySpec.AgentTasks.ReadyForQa
  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Requirements
  alias CodeMySpec.Stories
  alias CodeMySpec.Utils

  @doc """
  Read failing spex problems and build a fix prompt.

  Filters to failures whose component has a satisfied `implementation_file`
  requirement (i.e. the component code exists and should be fixable).

  Returns `{:ok, prompt_text}`.
  """
  def command(scope, task) do
    case story_for(scope, task) do
      nil -> project_command(scope)
      story -> story_command(scope, story)
    end
  end

  # Per story: a story's task lists only that story's failures, so the agent
  # is never sent into components it was not asked to touch.
  defp story_command(scope, story) do
    case story_spex_problems(scope, story) do
      [] -> {:ok, green_message(story)}
      problems -> prompt_for(scope, problems)
    end
  end

  defp project_command(scope) do
    prompt_for(scope, Problems.list_project_problems(scope, source: "spex"))
  end

  defp prompt_for(scope, problems) do
    if Enum.empty?(problems) do
      {:ok, no_failures_message()}
    else
      relevant = filter_relevant_problems(scope, problems)

      if Enum.empty?(relevant) do
        {:ok, unimplemented_message()}
      else
        {:ok, build_prompt(scope, relevant)}
      end
    end
  end

  @doc """
  Completing this task is the ready-for-QA certification (`ReadyForQa`).

  A story's specs are required green by `Promotion.certify/3`, at ready-for-QA
  and again at promotion, so this delegates.
  """
  def evaluate(scope, task), do: ReadyForQa.evaluate(scope, task)

  @doc "As `evaluate/2`, told who owns the task (`ReadyForQa.evaluate/3`)."
  def evaluate(scope, task, owner), do: ReadyForQa.evaluate(scope, task, owner)

  defp story_for(scope, %{story_id: story_id}) when not is_nil(story_id),
    do: Stories.get_story(scope, story_id)

  defp story_for(_scope, _task), do: nil

  # Spex problems whose file belongs to this story, matched on the file
  # records' `story_id` (resolved by the sync from the spec itself), never
  # parsed from directory names. An unlinked spec is not this story's problem.
  defp story_spex_problems(scope, story) do
    story_paths =
      scope
      |> Files.list_story_files(story.id)
      |> Enum.filter(&(&1.role == :bdd_spec))
      |> MapSet.new(& &1.path)

    scope
    |> Problems.list_project_problems(source: "spex")
    |> Enum.filter(&MapSet.member?(story_paths, &1.file_path))
  end

  # ============================================================================
  # Problem Filtering
  # ============================================================================

  # Same linkage as the gate, for the same reason: the prompt and the evaluator
  # have to agree on which story a failing spec belongs to, or an agent is shown
  # failures it will not be credited for fixing.
  defp filter_relevant_problems(scope, problems) do
    story_id_by_path = Files.bdd_spec_story_id_by_path(scope)

    problems
    |> Enum.map(fn problem ->
      {problem, Map.get(story_id_by_path, problem.file_path)}
    end)
    |> Enum.reject(fn {_problem, story_id} -> is_nil(story_id) end)
    |> Enum.group_by(fn {_problem, story_id} -> story_id end)
    |> Enum.flat_map(fn {story_id, problem_pairs} ->
      expand_story_problems(scope, story_id, problem_pairs)
    end)
  end

  defp expand_story_problems(scope, story_id, problem_pairs) do
    with story when not is_nil(story) <- Stories.get_story(scope, story_id),
         true <- story.component_id != nil,
         true <- component_implemented?(scope, story.component_id) do
      Enum.map(problem_pairs, fn {problem, _story_id} -> {problem, story} end)
    else
      _ -> []
    end
  end

  defp component_implemented?(scope, component_id) do
    case Components.get_component(scope, component_id) do
      nil ->
        false

      component ->
        Requirements.compute_component_requirements(scope, component)
        |> Enum.any?(fn req ->
          req.name == "implementation_file" && req.satisfied == true
        end)
    end
  end

  # ============================================================================
  # Messages
  # ============================================================================

  defp no_failures_message do
    """
    # Fix BDD Specs

    All BDD specs are passing. Nothing to fix.
    """
  end

  # Green specs do not complete the task by themselves; the prompt says that
  # evaluating it is the step that certifies (`ReadyForQa`).
  defp green_message(story) do
    """
    # Specs Passing — complete to certify

    Story #{story.number} (#{story.title}) has no failing spex problems recorded. The
    work looks done.

    Commit, then call `evaluate_task` on this task. Completing it certifies this
    copy for QA: a clean tree, every analyzer clean at your HEAD, and this story's
    own specs green there. If a run at your HEAD is missing it is started and the
    task stays open — end your turn; you are told when it lands.

    Other stories may have failing specs. They are not yours and they do not
    gate this certification.
    """
  end

  defp unimplemented_message do
    """
    # Fix BDD Specs

    All failing BDD specs belong to components that have not yet been implemented \
    (missing `implementation_file` requirement). Nothing to fix until the components are built.
    """
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(scope, relevant_pairs) do
    project = scope.active_project

    grouped = Enum.group_by(relevant_pairs, fn {_problem, story} -> story.id end)

    story_sections =
      Enum.map_join(grouped, "\n\n", fn {_story_id, pairs} ->
        {_problem, story} = List.first(pairs)
        problems = Enum.map(pairs, fn {p, _s} -> p end)
        build_story_section(project, story, problems)
      end)

    """
    # Fix BDD Specs

    The following BDD specs are failing. Fix the implementation code so the specs pass.

    ## Goal

    For each failing spec:

    1. **Read the spec file** to understand what behavior is expected
    2. **Read the implementation code** to understand the current state
    3. **Fix the implementation** so the spec passes
    4. **Run the spec** to verify: `mix test <spec_file_path>`
    5. **Run all tests** after fixing: `mix test`

    ## Important

    - Fix the **implementation code**, not the specs — specs define the expected behavior
    - Only modify specs if they have genuine bugs (wrong assertions, incorrect setup)
    - Keep fixes minimal and focused
    - #{WriteBddSpecs.obsolete_criterion()}

    ## Failing Specs

    #{story_sections}
    """
  end

  defp build_story_section(project, story, problems) do
    story_scope = %CodeMySpec.Users.Scope{
      active_project_id: story.project_id,
      active_project: project
    }

    component = Components.get_component(story_scope, story.component_id)
    files = if component, do: Utils.component_files(component, project), else: %{}

    failure_details =
      Enum.map_join(problems, "\n", fn problem ->
        """
        - `#{problem.file_path}`#{if problem.line, do: ":#{problem.line}", else: ""} — #{problem.message}
        """
      end)

    """
    ## Story #{story.number}: #{story.title}

    **Component**: #{if component, do: component.module_name, else: "unknown"}
    #{if files[:code_file], do: "**Implementation**: `#{files[:code_file]}`", else: ""}
    #{if files[:test_file], do: "**Tests**: `#{files[:test_file]}`", else: ""}

    **Failures:**
    #{failure_details}
    """
  end
end
