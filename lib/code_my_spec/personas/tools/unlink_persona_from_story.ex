defmodule CodeMySpec.Personas.Tools.UnlinkPersonaFromStory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Tools
  alias CodeMySpec.Stories

  @impl true
  def name, do: "unlink_persona_from_story"

  @impl true
  def description do
    """
    Removes a persona ↔ story link from the `persona_stories` join table.
    Rejects cross-project attempts. The persona itself is left intact.
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
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- Stories.fetch_story_by_number(scope, params[:story_number]),
         {:ok, :unlinked} <-
           Personas.unlink_persona_from_story(scope, params[:persona_id], story.id) do
      {:ok, Tools.unlink_text(params[:persona_id], story)}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end
end
