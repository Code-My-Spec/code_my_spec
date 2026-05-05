defmodule CodeMySpec.McpServers.Stories.Tools.StartStoryInterview do
  @moduledoc """
  Starts a guided story interview with the PM — develop and refine bare
  user stories through structured questioning. Acceptance criteria are
  out of scope; those land later in a Three Amigos session
  (see `start_three_amigos_session`).

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
         {:ok, prompt} <- StoryInterview.command(scope, %{session_type: "story_interview"}) do
      {:reply, StoriesMapper.prompt_response(prompt), frame}
    else
      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
