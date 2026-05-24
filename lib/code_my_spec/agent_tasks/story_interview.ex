defmodule CodeMySpec.AgentTasks.StoryInterview do
  @moduledoc """
  Run a guided story interview or review session with the PM.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/story_interview.spec.md`.
  """

  alias CodeMySpec.Requirements.{CheckerResult, StoriesChecker}
  alias CodeMySpec.Stories

  @spec analyzers() :: [atom()]
  def analyzers, do: []

  @spec dispatch(map()) :: String.t()
  def dispatch(_node) do
    "Run a story interview / review session with the PM — capture bare user " <>
      "stories (persona, goal, business value) or evaluate existing stories. " <>
      "Acceptance criteria come later via Three Amigos. Use when " <>
      "`stories_exist` is unsatisfied (interview) or for explicit review."
  end

  @spec command(term(), map()) :: {:ok, String.t()} | {:error, term()}
  def command(scope, task) do
    mode = mode_from_task(task)

    case Stories.list_project_stories(scope) do
      {:ok, stories} ->
        {:ok, build_prompt(mode, stories)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec evaluate(term(), map()) :: {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(_scope, %{session_type: "story_review"}), do: {:ok, :valid}

  def evaluate(scope, _task) do
    scope |> StoriesChecker.exist?(nil) |> CheckerResult.to_evaluation()
  end

  defp mode_from_task(%{session_type: "story_review"}), do: :review
  defp mode_from_task(_), do: :interview

  # ============================================================================
  # Prompt assembly. Protocol detail lives in the framework knowledge library
  # at `story_interview/workflow.md` (read via the `read_knowledge` MCP tool)
  # — pointed at via the playbook section rather than inlined here.
  # ============================================================================

  defp build_prompt(:interview, stories) do
    """
    # Story Interview

    You are an expert Product Manager helping another PM produce a set of
    bare user stories through thoughtful questioning. **Acceptance criteria
    are out of scope** — those come later via Three Amigos.

    ## Current stories on project

    #{format_stories(stories, :basic)}

    ## Read the playbook

    Read `story_interview/workflow.md` via the `read_knowledge` MCP tool
    — interview-mode role, CRITICAL user-story quality rules (persona
    must be human, "As a... I want... so that..." format, business value),
    out-of-scope items deferred to Three Amigos, MCP tool surface.

    Persist each finalized story via the `create_story` / `update_story`
    MCP tools.
    """
  end

  defp build_prompt(:review, stories) do
    """
    # Story Review

    You are an expert Product Manager conducting a story-level review.
    Evaluate completeness and quality of the bare stories on this project.
    **This is a story review — not an acceptance-criteria review.**

    ## Current stories

    #{format_stories(stories, :numbered)}

    ## Read the playbook

    Read `story_interview/workflow.md` via the `read_knowledge` MCP tool
    — review-mode procedure, persona validation rules (flag
    technical/system personas), review criteria and process, MCP tool
    surface.

    Give specific, actionable feedback per story. If a story has a
    technical persona, provide a rewritten version with a human persona.
    """
  end

  # ---------------------------------------------------------------------------
  # Story formatting
  # ---------------------------------------------------------------------------

  defp format_stories([], _style), do: "No stories currently exist for this project."

  defp format_stories(stories, :basic) do
    Enum.map_join(stories, "\n\n", &format_story_basic/1)
  end

  defp format_stories(stories, :numbered) do
    stories
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", &format_story_numbered/1)
  end

  defp format_story_basic(story) do
    """
    **#{story.title}**
    #{story.description}
    """
  end

  defp format_story_numbered({story, index}) do
    """
    **Story #{index}: #{story.title}**
    Description: #{story.description}
    """
  end
end
