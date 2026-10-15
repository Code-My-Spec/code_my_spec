defmodule CodeMySpec.Personas.Tools.LinkPersonaToStory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Tools

  @impl true
  def name, do: "link_persona_to_story"

  @impl true
  def description do
    """
    Links an existing persona to a story via the persona_stories join table.
    Rejects cross-project attempts.
    """
  end

  @impl true
  def params do
    %{
      persona_id:
        {:required, {:meta, :string, [description: "UUID of the persona on the active project."]}},
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- Tools.scope(context),
         {:ok, story} <- Tools.fetch_story(scope, params[:story_number]),
         {:ok, persona_story} <-
           Personas.link_persona_to_story(scope, params[:persona_id], story.id) do
      {:ok, Tools.link_text(persona_story, story)}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end
end
