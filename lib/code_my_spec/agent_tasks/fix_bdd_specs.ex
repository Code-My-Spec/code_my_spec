defmodule CodeMySpec.AgentTasks.FixBddSpecs do
  @moduledoc """
  Agent task for fixing failing BDD specifications.

  Reads spex failures from the Problems table, derives which stories and components
  they belong to, filters to only failures whose component has a satisfied
  `implementation_file` requirement, and builds a prompt instructing the agent to
  fix the implementation code so the specs pass.

  Two main functions:
  - `command/3` — Reads spex problems, builds fix prompt with failure details
  - `evaluate/3` — the ready-for-QA certification (`ReadyForQa`)
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

  # The gate is per story and so is the prompt.
  #
  # It used to ignore `task` entirely and list every spex failure in the
  # project. Asked for story 885 it returned twenty failures across 841, 851,
  # 852, 858, 859, 871 and 883 — not one of them 885's — under the heading "the
  # following BDD specs are failing" and the instructions "fix the
  # implementation code" and "read the implementation code". An agent that
  # follows its task prompt, which is the first rule in CLAUDE.md, goes and
  # edits eight components it was never asked to touch. In the reported case
  # that meant another agent's devops territory, which it had been told
  # explicitly to stay out of.
  #
  # `evaluate/2` was filtering correctly the whole time, through
  # `story_spex_problems/2`, and passed instantly on the same task. So the
  # evaluator knew the failures were irrelevant and the prompt did not.
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

  The specs-passing gate it used to evaluate is gone (John, 2026-10-02): no
  requirement reads analysis results any more, and a story's specs are
  required green by `Promotion.certify/3` — at ready-for-QA and again at
  promotion. So this delegates, which is also what lets a task held on the
  retired `bdd_specs_passing` complete through the new check.
  """
  def evaluate(scope, task), do: ReadyForQa.evaluate(scope, task)

  @doc "As `evaluate/2`, told who owns the task (`ReadyForQa.evaluate/3`)."
  def evaluate(scope, task, owner), do: ReadyForQa.evaluate(scope, task, owner)

  defp story_for(scope, %{story_id: story_id}) when not is_nil(story_id),
    do: Stories.get_story(scope, story_id)

  defp story_for(_scope, _task), do: nil

  # Spex problems whose file belongs to THIS story. Without the scoping a
  # single red spex anywhere in the project would hold every story short
  # of ready — the exact symptom the deleted per-story checker guarded
  # against.
  #
  # Matched on `files.story_id`, which the sync resolves from the spec itself.
  # Both previous attempts parsed the directory name and both were wrong for
  # most of a project, in opposite directions: comparing to `story.id` "matched
  # nothing once the two diverged", and comparing to `story.number` matched
  # nothing for every directory named from an id.
  #
  # Neither failure was visible, because this feeds a `cond` whose empty branch
  # latches `specs_ready`. A story whose specs could not be found read as a
  # story whose specs all passed. Measured on Broken Oaths 2026-09-08: 38 of 54
  # spec directories were id-prefixed, and 47 of 61 stories carried
  # `specs_ready: true` over 127 red specs for features nobody had written —
  # so `bdd_specs_passing` stopped being actionable and the only coding work
  # the graph could still offer was writing yet more specs.
  #
  # A path lookup cannot fail this way. If a spec file is not linked to a story
  # it simply is not that story's problem, and the gate stays shut rather than
  # opening on an empty list.
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

  # The state that cost the reporter most of a session: specs green, latch not
  # set, and the old prompt answering with other stories' failures.
  #
  # `bdd_specs_passing` reads `story.specs_ready`, and the only thing that sets
  # it is `evaluate/2` reaching its empty-problems branch. A completed sweep
  # does not set it. So three full spex runs — 213s, one killed at 12 minutes,
  # 393s — all landed green and the requirement stayed unsatisfied, with nothing
  # anywhere saying that an evaluation was the missing step. Three wrong
  # theories were built to explain it and one was filed as an issue that had to
  # be withdrawn.
  #
  # Completing the task is the ready-for-QA certification (`ReadyForQa`).
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

  # ============================================================================
  # Feedback
  # ============================================================================
end
