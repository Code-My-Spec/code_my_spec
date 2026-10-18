defmodule CodeMySpec.Stories.Tools.RetireStory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "retire_story"

  @impl true
  def description do
    """
    Retires a user story. There is no delete.

    A retired story keeps its number, which is never given to another story,
    leaves the backlog and the graph, and its criteria retire with it. Linked
    issues keep their link.
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
         {:ok, story} <- Stories.retire_story(scope, story) do
      StoriesMapper.story_retired_response(story)
    else
      nil ->
        StoriesMapper.not_found_error()

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
