defmodule CodeMySpec.Stories.Tools.RestoreStory do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "restore_story"

  @impl true
  def description do
    """
    Brings a retired story back under its number, with the criteria that were
    retired with it.

    The story comes back parked. Release it with
    `update_story(ready_for_dev: true)` to put it back to work.
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
         {:ok, story} <- Stories.restore_story(scope, story) do
      StoriesMapper.story_restored_response(story)
    else
      nil ->
        StoriesMapper.not_found_error()

      {:error, :not_retired} ->
        StoriesMapper.error("That story is not retired, so there is nothing to restore.")

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
