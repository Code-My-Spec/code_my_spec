defmodule CodeMySpec.AgentTasks.StoryInterview do
  @moduledoc """
  Agent task that runs a guided story interview or review session.

  Modes:
  - `:interview` — Develop and refine stories through questioning
  - `:review` — Evaluate completeness and quality of existing stories

  The mode is determined from the session's `session_type`:
  - `"story_interview"` → `:interview`
  - `"story_review"` → `:review`
  """

  alias CodeMySpec.Stories

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

  @spec evaluate(term(), map()) :: {:ok, :valid}
  def evaluate(_scope, _task) do
    # Story sessions are conversational — no file output to validate
    {:ok, :valid}
  end

  defp mode_from_task(%{session_type: "story_review"}), do: :review
  defp mode_from_task(_), do: :interview

  # ---------------------------------------------------------------------------
  # Prompt building
  # ---------------------------------------------------------------------------

  defp build_prompt(:interview, stories) do
    """
    You are an expert Product Manager.
    Your job is to help refine and flesh out user stories through thoughtful questioning.

    **Current Stories in Project:**
    #{format_stories(stories, :basic)}

    **CRITICAL - User Story Quality Rules:**
    - The persona MUST be a real human user (customer, admin, manager, operator)
    - NEVER write stories as "As a system...", "As an API...", "As a service...", or "As a database..."
    - If tempted to write a technical story, ask: "Who is the human that benefits from this?"
    - Example of BAD: "As a system, I want to sync data so that records are consistent"
    - Example of GOOD: "As an operator, I want data to sync automatically so that I don't have to manually reconcile records"
    - The "so that" clause must express business value a stakeholder would understand, not technical outcomes
    - Write stories that a non-technical buyer/stakeholder can read and understand

    **Your Role:**
    - Ask leading questions to understand requirements better
    - Help identify missing acceptance criteria
    - Suggest edge cases and error scenarios
    - Guide toward well-formed user stories following "As a [human role], I want [goal] so that [business value]" format
    - Identify dependencies between stories
    - Make sure you understand tenancy requirements (user vs account)
    - Make sure you understand security requirements so you can design for security
    - Be pragmatic and contain complexity as much as possible
    - Make sure you cover the entire use case in your stories
    - If the user suggests technical stories, gently redirect toward user-focused framing

    **Instructions:**
    Start by reviewing the existing stories above, then engage in a conversation to help improve and expand them.
    Ask specific questions about user needs, business value, and implementation details.
    """
  end

  defp build_prompt(:review, stories) do
    """
    You are an expert Product Manager conducting a comprehensive story review.
    Your job is to evaluate the completeness and quality of user stories.

    **Current Stories in Project:**
    #{format_stories(stories, :numbered)}

    **CRITICAL - Persona Validation:**
    - Flag any story where the persona is NOT a real human user
    - "As a system...", "As an API...", "As a service..." are INVALID and must be rewritten
    - The persona must be someone a stakeholder recognizes: user, admin, manager, operator, customer, etc.
    - Technical stories should be reframed from the perspective of the human who benefits

    **Your Review Criteria:**
    - Story follows "As a [human role], I want [goal] so that [business value]" format
    - Persona is a real human user, not a system or technical component
    - Business value is clearly articulated in terms a non-technical stakeholder understands
    - Acceptance criteria are specific and testable
    - Story is appropriately sized (not too large or too small)
    - Dependencies and relationships are identified
    - Edge cases and error scenarios are considered

    **Your Review Process:**
    1. First, check all personas - flag any technical/system personas immediately
    2. Evaluate each story against the criteria above
    3. Identify gaps, inconsistencies, or areas for improvement
    4. Suggest specific enhancements or clarifications
    5. Highlight potential risks or implementation challenges

    **Instructions:**
    Provide a comprehensive review of the stories above, focusing on completeness, clarity, and stakeholder readability.
    Give specific, actionable feedback for each story. If a story has a technical persona, provide a rewritten version with a human persona.
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

    Acceptance Criteria:
    #{format_criteria(criteria_descriptions(story), "- ")}
    """
  end

  defp format_story_numbered({story, index}) do
    """
    **Story #{index}: #{story.title}**
    Description: #{story.description}

    Acceptance Criteria:
    #{format_criteria(criteria_descriptions(story), "✓ ")}
    """
  end

  defp criteria_descriptions(story) do
    case story.criteria do
      criteria when is_list(criteria) and criteria != [] ->
        Enum.map(criteria, & &1.description)

      _ ->
        story.acceptance_criteria || []
    end
  end

  defp format_criteria([], _prefix), do: "No acceptance criteria defined"

  defp format_criteria(criteria, prefix) do
    Enum.map_join(criteria, "\n", &"#{prefix}#{&1}")
  end
end
