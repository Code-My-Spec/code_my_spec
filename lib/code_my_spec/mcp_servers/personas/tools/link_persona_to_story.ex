defmodule CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory do
  @moduledoc """
  Links an existing persona to a story via the persona_stories join table.
  Rejects cross-project attempts.
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
         {:ok, persona_story} <-
           Personas.link_persona_to_story(scope, params[:persona_id], story.id) do
      {:reply, PersonasMapper.link_response(persona_story, story), frame}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, PersonasMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, PersonasMapper.error(reason), frame}
    end
  end
end
