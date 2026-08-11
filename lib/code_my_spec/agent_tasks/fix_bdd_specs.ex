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

  def analyzers, do: [:spex_stale]

  def dispatch(_node) do
    "Fix the failing BDD spec files for a story — diagnose the failure (test " <>
      "assertion, missing fixture, surface mismatch), edit the spec or the " <>
      "underlying implementation, and re-run `mix spex` until green. Use " <>
      "when a story's BDD spec files exist but one or more criteria fail."
  end

  alias CodeMySpec.Analysis
  alias CodeMySpec.BddSpecs.Parser
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
  Evaluate the specs-passing gate for the task's story and, on a pass,
  set the story's specs-ready latch.

  The gate is a latch, not a running tally. It requires a *fresh* spex
  run showing every one of the story's own specs green; once that lands,
  `Stories.set_specs_ready/3` records it and `bdd_specs_passing` reads
  the field from then on. A later edit that stales the run leaves the
  latch alone — that asymmetry is the whole reason the node can exist
  again. bab2f792 removed it because freshness was re-evaluated forever,
  so nearly any edit dropped it back to "analysis pending" and clamped
  qa_complete behind it.

  Staleness is reported as *pending*, never as *failure*: an agent told
  its specs failed goes hunting for a bug that isn't there.

  Returns:
  - `{:ok, :valid}` when the story's specs are green on a fresh run
  - `{:ok, :invalid, feedback}` when specs fail, are missing, or the run
    is not yet current
  """
  def evaluate(scope, task) do
    case story_for(scope, task) do
      nil ->
        {:ok, :invalid, "No story found for this task — cannot evaluate the specs-passing gate."}

      story ->
        evaluate_story(scope, story)
    end
  end

  defp evaluate_story(scope, story) do
    cond do
      story.specs_ready == true ->
        # Already latched. A stale run or a fresh failure elsewhere must
        # not un-latch it; only a chain restart or a manual clear does.
        {:ok, :valid}

      not has_bdd_specs?(scope, story) ->
        {:ok, :invalid, no_specs_message(story)}

      not Analysis.fresh?(scope, "spex") ->
        {:ok, :invalid, analysis_pending_message(story)}

      true ->
        case story_spex_problems(scope, story) do
          [] ->
            {:ok, _story} = Stories.set_specs_ready(scope, story, true)
            {:ok, :valid}

          problems ->
            {:ok, :invalid, build_feedback(Enum.map(problems, &{&1, story}))}
        end
    end
  end

  defp story_for(scope, %{story_id: story_id}) when not is_nil(story_id),
    do: Stories.get_story(scope, story_id)

  defp story_for(_scope, _task), do: nil

  # Spex problems whose file belongs to THIS story. Without the scoping a
  # single red spex anywhere in the project would hold every story short
  # of ready — the exact symptom the deleted per-story checker guarded
  # against.
  # Matched on `story.number`, because that is what the directory is named
  # from. Comparing the parsed number to `story.id` matched nothing once the
  # two diverged, so every story looked like it had no failing spex.
  defp story_spex_problems(scope, story) do
    scope
    |> Problems.list_project_problems(source: "spex")
    |> Enum.filter(&(Parser.derive_story_number(&1.file_path) == story.number))
  end

  defp has_bdd_specs?(scope, story) do
    scope
    |> Files.list_story_files(story.id)
    |> Enum.any?(&(&1.role == :bdd_spec))
  end

  # ============================================================================
  # Problem Filtering
  # ============================================================================

  defp filter_relevant_problems(scope, problems) do
    by_number = Stories.list_story_ids_by_number(scope)

    problems
    |> Enum.map(fn problem ->
      story_id = Map.get(by_number, Parser.derive_story_number(problem.file_path))
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

  defp no_specs_message(story) do
    """
    # Specs Passing — not yet

    Story #{story.id} (#{story.title}) has no BDD spec files on disk, so there is
    nothing for a spex run to prove. Write the story's specs first
    (`bdd_specs_exist`), then come back to this gate.
    """
  end

  # Deliberately worded as pending rather than failing. A stale run means
  # "we don't know yet", and an agent told its specs failed will go looking
  # for a bug that isn't there.
  defp analysis_pending_message(story) do
    """
    # Specs Passing — analysis pending

    Story #{story.id} (#{story.title}) cannot be flipped to specs-ready yet: the
    latest spex run does not cover the current state of the code. This is
    **not** a spec failure — nothing is known to be broken.

    Wait for the in-flight spex run with
    `curl -sS -X POST localhost:4004/api/analysis/wait` — run it in the
    background and you will be notified when it returns — then evaluate this
    requirement again.
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
