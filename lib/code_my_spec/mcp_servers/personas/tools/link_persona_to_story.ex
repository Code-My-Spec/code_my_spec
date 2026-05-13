defmodule CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory do
  @moduledoc """
  Links an existing persona to a story via the persona_stories join table.
  Rejects cross-project attempts.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
    field :persona_id, :string, required: true, doc: "UUID of the persona on the active project."
    field :story_id, :integer, required: true, doc: "ID of the story to link to."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, persona_story} <-
           Personas.link_persona_to_story(scope, params[:persona_id], params[:story_id]) do
      {:reply, PersonasMapper.link_response(persona_story), frame}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, PersonasMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, PersonasMapper.error(reason), frame}
    end
  end
end
