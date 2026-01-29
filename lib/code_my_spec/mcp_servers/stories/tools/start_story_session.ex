defmodule CodeMySpec.McpServers.Stories.Tools.StartStorySession do
  @moduledoc """
  Starts a guided session for working with user stories.

  Modes:
  - "interview": Develop and refine stories through questioning
  - "review": Evaluate completeness and quality of existing stories
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :mode, :string,
      required: true,
      doc: "Session mode: 'interview' to develop stories, 'review' to evaluate them"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         {:ok, mode} <- validate_mode(params.mode),
         {:ok, stories} <- Stories.list_project_stories(scope) do
      prompt = build_prompt(mode, stories)
      {:reply, StoriesMapper.prompt_response(prompt), frame}
    else
      {:error, :invalid_mode} ->
        {:reply, StoriesMapper.error("Invalid mode. Use 'interview' or 'review'."), frame}

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end

  defp validate_mode("interview"), do: {:ok, :interview}
  defp validate_mode("review"), do: {:ok, :review}
  defp validate_mode(_), do: {:error, :invalid_mode}

  defp build_prompt(:interview, stories) do
    """
    You are an expert Product Manager.
    Your job is to help refine and flesh out user stories through thoughtful questioning.


    **Current Stories in Project:**
    #{format_stories_for_interview(stories)}

    **Your Role:**
    - Ask leading questions to understand requirements better
    - Help identify missing acceptance criteria
    - Suggest edge cases and error scenarios
    - Guide toward well-formed user stories following "As a... I want... So that..." format
    - Identify dependencies between stories
    - Make sure you understand tenancy requirements (user vs account)
    - Make sure you understand security requirements so you can design for security
    - Be pragmatic and contain complexity as much as possible
    - Make sure you cover the entire use case in your stories

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
    #{format_stories_for_review(stories)}

    **Your Review Criteria:**
    - Story follows "As a... I want... So that..." format
    - Business value is clearly articulated
    - Acceptance criteria are specific and testable
    - Story is appropriately sized (not too large or too small)
    - Dependencies and relationships are identified
    - Edge cases and error scenarios are considered

    **Your Review Process:**
    1. Evaluate each story against the criteria above
    2. Identify gaps, inconsistencies, or areas for improvement
    3. Suggest specific enhancements or clarifications
    4. Highlight potential risks or implementation challenges

    **Instructions:**
    Provide a comprehensive review of the stories above, focusing on completeness, clarity, and technical feasibility.
    Give specific, actionable feedback for each story.
    """
  end

  defp format_stories_for_interview([]), do: "No stories currently exist for this project."

  defp format_stories_for_interview(stories) do
    stories
    |> Enum.map(&format_story_basic/1)
    |> Enum.join("\n\n")
  end

  defp format_stories_for_review([]), do: "No stories currently exist for this project."

  defp format_stories_for_review(stories) do
    stories
    |> Enum.with_index(1)
    |> Enum.map(&format_story_numbered/1)
    |> Enum.join("\n\n")
  end

  defp format_story_basic(story) do
    criteria = format_criteria(story.acceptance_criteria, "- ")

    """
    **#{story.title}**
    #{story.description}

    Acceptance Criteria:
    #{criteria}
    """
  end

  defp format_story_numbered({story, index}) do
    criteria = format_criteria(story.acceptance_criteria, "✓ ")

    """
    **Story #{index}: #{story.title}**
    Description: #{story.description}

    Acceptance Criteria:
    #{criteria}
    """
  end

  defp format_criteria([], _prefix), do: "No acceptance criteria defined"

  defp format_criteria(criteria, prefix) do
    criteria
    |> Enum.map(&"#{prefix}#{&1}")
    |> Enum.join("\n")
  end
end
