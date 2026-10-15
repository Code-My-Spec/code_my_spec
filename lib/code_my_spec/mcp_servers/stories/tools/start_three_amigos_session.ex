defmodule CodeMySpec.McpServers.Stories.Tools.StartThreeAmigosSession do
  @moduledoc """
  Starts a Three Amigos / Example Mapping session on a single story.

  Returns the protocol prompt the agent uses to drive the workshop with
  the PM — persona linkage, rules (blue cards), scenarios (green cards),
  and questions (red cards). Delegates prompt building to
  `CodeMySpec.AgentTasks.ThreeAmigos`.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AgentTasks.ThreeAmigos
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :story_number, :integer,
      required: true,
      description: "Story number (list_story_titles shows them)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         story when not is_nil(story) <- Stories.get_story_by_number(scope, params.story_number),
         {:ok, prompt} <-
           ThreeAmigos.command(scope, %{entity_type: :story, entity_id: to_string(story.id)}) do
      {:reply, StoriesMapper.prompt_response(prompt), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
