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

  schema do
    field :story_id, :string,
      required: true,
      doc: "Story ID to host the Three Amigos session"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, prompt} <- ThreeAmigos.command(scope, %{entity_type: :story, entity_id: params.story_id}) do
      {:reply, StoriesMapper.prompt_response(prompt), frame}
    else
      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end
end
