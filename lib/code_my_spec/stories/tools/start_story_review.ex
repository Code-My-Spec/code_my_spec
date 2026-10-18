defmodule CodeMySpec.Stories.Tools.StartStoryReview do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.AgentTasks.StoryInterview
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper

  @impl true
  def name, do: "start_story_review"

  @impl true
  def description do
    """
    Starts a story-level review with the PM — evaluate completeness and
    quality of existing bare user stories. Acceptance criteria are not
    reviewed here; those are produced and reviewed during Three Amigos.

    Delegates prompt building to `CodeMySpec.AgentTasks.StoryInterview`.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, prompt} <- StoryInterview.command(scope, %{session_type: "story_review"}) do
      StoriesMapper.prompt_response(prompt)
    else
      {:error, reason} ->
        StoriesMapper.error(reason)
    end
  end
end
