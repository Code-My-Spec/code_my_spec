defmodule CodeMySpec.AgentTasks.FixBddSpecs do
  @moduledoc """
  Agent task for fixing failing BDD specifications.

  Reads spex failures from the Problems table, derives which stories and components
  they belong to, filters to only failures whose component has a satisfied
  `implementation_file` requirement, and builds a prompt instructing the agent to
  fix the implementation code so the specs pass.

  Two main functions:
  - `command/3` — Reads spex problems, builds fix prompt with failure details
  - `evaluate/3` — Checks that no relevant spex failures remain
  """

  alias CodeMySpec.BddSpecs.Parser
  alias CodeMySpec.Components
  alias CodeMySpec.Problems
  alias CodeMySpec.Stories
  alias CodeMySpec.Utils

  require Logger

  @doc """
  Read failing spex problems and build a fix prompt.

  Filters to failures whose component has a satisfied `implementation_file`
  requirement (i.e. the component code exists and should be fixable).

  Returns `{:ok, prompt_text}`.
  """
  def command(scope, _task) do
    problems = Problems.list_project_problems(scope, source: "spex")

    if Enum.empty?(problems) do
      {:ok, no_failures_message()}
    else
      relevant = filter_relevant_problems(scope, problems)

      if Enum.empty?(relevant) do
        {:ok, unimplemented_message()}
      else
        prompt = build_prompt(scope, relevant)
        {:ok, prompt}
      end
    end
  end

  @doc """
  Check that no relevant spex failures remain.

  Returns:
  - `{:ok, :valid}` when no relevant failures exist
  - `{:ok, :invalid, feedback}` when relevant failures remain
  """
  def evaluate(scope, _task) do
    problems = Problems.list_project_problems(scope, source: "spex")

    if Enum.empty?(problems) do
      {:ok, :valid}
    else
      relevant = filter_relevant_problems(scope, problems)

      if Enum.empty?(relevant) do
        {:ok, :valid}
      else
        feedback = build_feedback(relevant)
        {:ok, :invalid, feedback}
      end
    end
  end

  # ============================================================================
  # Problem Filtering
  # ============================================================================

  defp filter_relevant_problems(scope, problems) do
    problems
    |> Enum.map(fn problem ->
      story_id = Parser.derive_story_id(problem.file_path)
      {problem, story_id}
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
        Enum.any?(component.requirements, fn req ->
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
    ## Story: #{story.title} (ID: #{story.id})

    **Component**: #{if component, do: component.module_name, else: "unknown"}
    #{if files[:code_file], do: "**Implementation**: `#{files[:code_file]}`", else: ""}
    #{if files[:test_file], do: "**Tests**: `#{files[:test_file]}`", else: ""}

    **Failures:**
    #{failure_details}
    """
  end

  # ============================================================================
  # Feedback
  # ============================================================================

  defp build_feedback(relevant_pairs) do
    lines =
      Enum.map_join(relevant_pairs, "\n", fn {problem, story} ->
        "- `#{problem.file_path}` (story: #{story.title}): #{problem.message}"
      end)

    "#{length(relevant_pairs)} BDD spec failure(s) remain for implemented components:\n\n#{lines}\n\nFix the implementation code so these specs pass."
  end
end
