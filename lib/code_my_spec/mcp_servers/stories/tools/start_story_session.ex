defmodule CodeMySpec.McpServers.Stories.Tools.StartStorySession do
  @moduledoc """
  Starts a guided session for working with user stories.

  Modes:
  - "interview": Develop and refine stories through questioning
  - "review": Evaluate completeness and quality of existing stories

  Delegates prompt building to `CodeMySpec.AgentTasks.StoryInterview`.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AgentTasks.StoryInterview
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
         {:ok, _mode} <- validate_mode(params.mode) do
      task = %{session_type: session_type(params.mode)}

      case StoryInterview.command(scope, task) do
        {:ok, prompt} ->
          {:reply, StoriesMapper.prompt_response(prompt), frame}

        {:error, reason} ->
          {:reply, StoriesMapper.error(reason), frame}
      end
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

  defp session_type("review"), do: "story_review"
  defp session_type(_), do: "story_interview"
end
