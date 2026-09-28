defmodule CodeMySpec.McpServers.Stories.Tools.RestoreStory do
  @moduledoc """
  Brings a retired story back under its number, with the criteria that were
  retired with it.

  The story comes back parked. Release it with
  `update_story(ready_for_dev: true)` to put it back to work.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :story_id, :string, required: true, doc: "ID of the retired story to restore"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         {:ok, story} <- Stories.restore_story(scope, story) do
      {:reply, StoriesMapper.story_restored_response(story), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, :not_retired} ->
        {:reply, StoriesMapper.error("That story is not retired, so there is nothing to restore."), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
