defmodule CodeMySpec.Stories.Tools.GetStory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "get_story"

  @impl true
  def description do
    """
    Gets a single story by number with full details including acceptance criteria.

    Use list_story_titles to find story numbers if you don't know them.
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
         story when not is_nil(story) <- Stories.get_story_by_number(scope, params.story_number) do
      StoriesMapper.story_get_response(story)
    else
      nil ->
        StoriesMapper.not_found_error()

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
