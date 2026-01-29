defmodule CodeMySpec.McpServers.Stories.Tools.AddStoryTag do
  @moduledoc """
  Adds a tag to a story for organization and categorization.

  Tags are simple string identifiers like "accounts", "notifications", "fraud-detection".
  Use tags to group related stories before running architecture analysis.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.Tags
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :string, required: true, doc: "Story ID to tag"
    field :tag, :string, required: true, doc: "Tag name (e.g., 'accounts', 'notifications', 'fraud-detection')"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         story when not is_nil(story) <- Stories.get_story(scope, params.story_id),
         {:ok, story_tag} <- Tags.add_tag(scope, story, params.tag) do
      tag = CodeMySpec.Repo.preload(story_tag, :tag).tag
      {:reply, StoriesMapper.tag_added_response(story, tag), frame}
    else
      nil ->
        {:reply, StoriesMapper.not_found_error(), frame}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Duplicate tag - return success anyway (idempotent)
        if has_unique_constraint_error?(changeset) do
          story = Stories.get_story!(elem(Validators.validate_scope(frame), 1), params.story_id)
          tag = Tags.get_or_create_tag(elem(Validators.validate_scope(frame), 1), params.tag) |> elem(1)
          {:reply, StoriesMapper.tag_already_exists_response(story, tag), frame}
        else
          {:reply, StoriesMapper.validation_error(changeset), frame}
        end

      {:error, reason} ->
        {:reply, StoriesMapper.error(reason), frame}
    end
  end

  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end
end
