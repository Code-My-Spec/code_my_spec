defmodule CodeMySpec.McpServers.Personas.Tools.UnlinkPersonaFromStory do
  @moduledoc """
  Removes a persona ↔ story link from the `persona_stories` join table.
  Rejects cross-project attempts. The persona itself is left intact.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.StoryRefs
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
    field :persona_id, :string, required: true, doc: "UUID of the persona on the active project."

    field :story_number, :integer,
      required: true,
      doc: "Story number (list_story_titles shows them)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, story} <- StoryRefs.fetch_story(scope, params[:story_number]),
         {:ok, :unlinked} <-
           Personas.unlink_persona_from_story(scope, params[:persona_id], story.id) do
      {:reply, PersonasMapper.unlink_response(params[:persona_id], story), frame}
    else
      {:error, reason} ->
        {:reply, PersonasMapper.error(reason), frame}
    end
  end
end
