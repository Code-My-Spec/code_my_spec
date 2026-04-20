defmodule CodeMySpec.McpServers.Stories.Tools.DeleteStory do
  @moduledoc """
  Deletes a user story permanently.

  Use list_story_titles to find story IDs. This action cannot be undone.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string,
      required: true,
      doc: "Story ID to delete (use list_story_titles to find IDs)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         {:ok, story} <- Stories.delete_story(scope, story) do
      {:reply, StoriesMapper.story_deleted_response(story), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
