defmodule CodeMySpec.AgentTasks.StoryInterview do
  @moduledoc """
  Agent task that runs a guided story interview or review session.

  Modes:
  - `:interview` — Develop and refine bare user stories through questioning
  - `:review` — Evaluate completeness and quality of existing stories

  The mode is determined from the session's `session_type`:
  - `"story_interview"` → `:interview`
  - `"story_review"` → `:review`

  Acceptance criteria, rules, and scenarios are NOT produced here — they
  are created later by the Three Amigos / Example Mapping pass on each
  story (see `CodeMySpec.AgentTasks.ThreeAmigos`). This task is the
  story intake step: capture the human persona, the goal, and the
  business value.

  Review-mode sessions evaluate as valid — they're an inspection pass
  with no graph gate.
  """

  alias CodeMySpec.Requirements.{CheckerResult, StoriesChecker}
  alias CodeMySpec.Stories

  @spec analyzers() :: [atom()]
  def analyzers, do: []

  @spec orchestrate(map()) :: String.t()
  def orchestrate(node) do
    "Run a story interview — interview the PM, capture bare user stories " <>
      "(persona, goal, business value). Acceptance criteria come later via " <>
      "Three Amigos. Call `start_task` with requirement_name `#{node.name}`, " <>
      "entity_type `#{node.entity_type}`, entity_id `#{node.entity_id}`."
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

  # ---------------------------------------------------------------------------
  # Prompt building
  # ---------------------------------------------------------------------------

  defp build_prompt(:interview, stories) do
    """
    You are an expert Product Manager.
    Your job is to help a fellow PM produce a set of bare user stories
    through thoughtful questioning. **Acceptance criteria are out of
    scope here** — those are created later in a Three Amigos /
    Example Mapping pass against each story. Do not write rules,
    scenarios, or acceptance criteria during this session.

    **Current Stories in Project:**
    #{format_stories(stories, :basic)}

    **CRITICAL — User Story Quality Rules:**
    - The persona MUST be a real human user (customer, admin, manager, operator)
    - NEVER write stories as "As a system...", "As an API...", "As a service...", or "As a database..."
    - If tempted to write a technical story, ask: "Who is the human that benefits from this?"
    - Example of BAD: "As a system, I want to sync data so that records are consistent"
    - Example of GOOD: "As an operator, I want data to sync automatically so that I don't have to manually reconcile records"
    - The "so that" clause must express business value a stakeholder would understand, not technical outcomes
    - Write stories that a non-technical buyer/stakeholder can read and understand

    **Your Role:**
    - Ask leading questions to understand who the user is, what they want to do, and why it matters to the business
    - Guide toward well-formed user stories following "As a [human role], I want [goal] so that [business value]" format
    - Identify dependencies between stories at the story level (story X must exist before story Y is meaningful)
    - Make sure you understand tenancy requirements (user vs account)
    - Be pragmatic and contain complexity — prefer fewer, well-scoped stories over many overlapping ones
    - Make sure you cover the entire use case across the set of stories
    - If the PM suggests technical stories, gently redirect toward user-focused framing

    **Out of scope for this session — defer to Three Amigos:**
    - Acceptance criteria
    - Rules and scenarios (Given/When/Then)
    - Edge cases and failure modes
    - Persona research artifacts (summary.md / sources.md)

    **Instructions:**
    Start by reviewing the existing stories above, then engage in a
    conversation to help the PM produce well-formed bare stories.
    Persist each finalized story via the stories MCP tools.
    """
  end

  defp build_prompt(:review, stories) do
    """
    You are an expert Product Manager conducting a story-level review.
    Your job is to evaluate the completeness and quality of the bare
    user stories on this project. **This is a story review — not an
    acceptance-criteria review.** Acceptance criteria are produced by
    Three Amigos sessions on each story; if you spot AC issues, note
    them but don't try to author or fix them here.

    **Current Stories in Project:**
    #{format_stories(stories, :numbered)}

    **CRITICAL — Persona Validation:**
    - Flag any story where the persona is NOT a real human user
    - "As a system...", "As an API...", "As a service..." are INVALID and must be rewritten
    - The persona must be someone a stakeholder recognizes: user, admin, manager, operator, customer, etc.
    - Technical stories should be reframed from the perspective of the human who benefits

    **Your Review Criteria:**
    - Story follows "As a [human role], I want [goal] so that [business value]" format
    - Persona is a real human user, not a system or technical component
    - Business value is clearly articulated in terms a non-technical stakeholder understands
    - Story is appropriately sized (not too large or too small)
    - Story-level dependencies and relationships are identified

    **Your Review Process:**
    1. Check all personas — flag any technical/system personas immediately
    2. Evaluate each story against the criteria above
    3. Identify gaps in coverage, redundancy across stories, or sizing problems
    4. Suggest specific rewrites where needed (title and description only)
    5. If a story looks ready for Three Amigos, say so

    **Instructions:**
    Provide a comprehensive review of the stories above, focusing on
    completeness, clarity, and stakeholder readability of the stories
    themselves. Give specific, actionable feedback for each story. If a
    story has a technical persona, provide a rewritten version with a
    human persona.
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
