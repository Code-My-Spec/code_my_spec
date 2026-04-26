defmodule CodeMySpec.McpServers.Personas.Tools.UnlinkPersonaFromStory do
  @moduledoc """
  Removes a persona ↔ story link from the `persona_stories` join table.
  Rejects cross-account attempts. The persona itself is left intact.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
    field :persona_id, :string, required: true, doc: "UUID of the persona in the active account."
    field :story_id, :integer, required: true, doc: "ID of the story to unlink."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, :unlinked} <-
           Personas.unlink_persona_from_story(scope, params[:persona_id], params[:story_id]) do
      {:reply, PersonasMapper.unlink_response(params[:persona_id], params[:story_id]), frame}
    else
      {:error, reason} ->
        {:reply, PersonasMapper.error(reason), frame}
    end
  end
end
