defmodule CodeMySpec.McpServers.Stories.Tools.RetireStory do
  @moduledoc """
  Retires a user story. There is no delete.

  A retired story keeps its number, which is never given to another story,
  leaves the backlog and the graph, and its criteria retire with it. Linked
  issues keep their link.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :story_id, :string,
      required: true,
      doc: "Story ID to retire (use list_story_titles to find IDs)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         {:ok, story} <- Stories.retire_story(scope, story) do
      {:reply, StoriesMapper.story_retired_response(story), frame}
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
