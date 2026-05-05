defmodule CodeMySpec.McpServers.Stories.Tools.StartStoryReview do
  @moduledoc """
  Starts a story-level review with the PM — evaluate completeness and
  quality of existing bare user stories. Acceptance criteria are not
  reviewed here; those are produced and reviewed during Three Amigos.

  Delegates prompt building to `CodeMySpec.AgentTasks.StoryInterview`.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AgentTasks.StoryInterview
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, prompt} <- StoryInterview.command(scope, %{session_type: "story_review"}) do
      {:reply, StoriesMapper.prompt_response(prompt), frame}
    else
      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
