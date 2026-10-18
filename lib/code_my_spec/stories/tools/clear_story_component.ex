defmodule CodeMySpec.Stories.Tools.ClearStoryComponent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "clear_story_component"

  @impl true
  def description do
    """
    Removes the component link from a story.

    Use this when a story is no longer satisfied by its assigned component.
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         story when not is_nil(story) <- Stories.get_story_by_number(scope, params.story_number),
         {:ok, updated_story} <- Stories.clear_story_component(scope, story) do
      StoriesMapper.story_component_cleared_response(updated_story)
    else
      nil ->
        StoriesMapper.error("Story not found")

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
