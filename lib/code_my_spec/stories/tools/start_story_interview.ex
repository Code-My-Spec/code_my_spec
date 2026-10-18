defmodule CodeMySpec.Stories.Tools.StartStoryInterview do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.AgentTasks.StoryInterview
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper

  @impl true
  def name, do: "start_story_interview"

  @impl true
  def description do
    """
    Starts a guided story interview with the PM — develop and refine bare
    user stories through structured questioning. Acceptance criteria are
    out of scope; those land later in a Three Amigos session
    (see `start_three_amigos_session`).

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
         {:ok, prompt} <- StoryInterview.command(scope, %{session_type: "story_interview"}) do
      StoriesMapper.prompt_response(prompt)
    else
      {:error, reason} ->
        StoriesMapper.error(reason)
    end
  end
end
