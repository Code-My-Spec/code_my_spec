defmodule CodeMySpec.Tags do
  @moduledoc """
  Simple tagging system for organizing stories.

  Tags are strings scoped to a project, and stories can have multiple tags.
  """

  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Tags.Tag
  alias CodeMySpec.Tags.StoryTag
  alias CodeMySpec.Tags.TagRepository
  alias CodeMySpec.Users.Scope

  # Delegated functions
  defdelegate list_project_tags(scope), to: TagRepository
  defdelegate get_tag!(scope, id), to: TagRepository
  defdelegate get_tag(scope, id), to: TagRepository
  defdelegate get_or_create_tag(scope, name), to: TagRepository

  @doc """
  Adds a tag to a story. Creates the tag if it doesn't exist.
  """
  @spec add_tag(Scope.t(), Story.t(), String.t()) :: {:ok, StoryTag.t()} | {:error, Ecto.Changeset.t()}
  def add_tag(%Scope{} = scope, %Story{} = story, tag_name) do
    with {:ok, tag} <- TagRepository.get_or_create_tag(scope, tag_name) do
      TagRepository.create_story_tag(%{tag_id: tag.id, story_id: story.id})
    end
  end

  @doc """
  Removes a tag from a story.
  """
  @spec remove_tag(Scope.t(), Story.t(), String.t()) :: :ok | {:error, :not_found}
  def remove_tag(%Scope{} = scope, %Story{} = story, tag_name) do
    case TagRepository.get_tag_by_name(scope, tag_name) do
      nil ->
        {:error, :not_found}

      tag ->
        case TagRepository.get_story_tag(tag.id, story.id) do
          nil -> {:error, :not_found}
          story_tag ->
            TagRepository.delete_story_tag(story_tag)
            :ok
        end
    end
  end

  @doc """
  Lists all tags for a story.
  """
  @spec list_story_tags(Scope.t(), Story.t()) :: [Tag.t()]
  def list_story_tags(%Scope{} = scope, %Story{} = story) do
    TagRepository.list_tags_for_story(scope, story.id)
  end

  @doc """
  Finds all stories with a given tag.
  """
  @spec find_stories_by_tag(Scope.t(), String.t()) :: [Story.t()]
  def find_stories_by_tag(%Scope{} = scope, tag_name) do
    case TagRepository.get_tag_by_name(scope, tag_name) do
      nil -> []
      tag -> TagRepository.find_stories_by_tag_id(scope, tag.id)
    end
  end

  @doc """
  Syncs story tags to match the provided list.
  Adds missing tags, removes extras. Idempotent.
  """
  @spec sync_tags(Scope.t(), Story.t(), [String.t()]) :: {:ok, Story.t()}
  def sync_tags(%Scope{} = scope, %Story{} = story, desired_tag_names) when is_list(desired_tag_names) do
    current_tags = list_story_tags(scope, story)
    current_names = MapSet.new(current_tags, & &1.name)
    desired_names = MapSet.new(desired_tag_names)

    # Add missing tags
    to_add = MapSet.difference(desired_names, current_names)
    Enum.each(to_add, fn name -> add_tag(scope, story, name) end)

    # Remove extra tags
    to_remove = MapSet.difference(current_names, desired_names)
    Enum.each(to_remove, fn name -> remove_tag(scope, story, name) end)

    {:ok, story}
  end
end
