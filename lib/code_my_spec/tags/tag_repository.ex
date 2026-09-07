defmodule CodeMySpec.Tags.TagRepository do
  @moduledoc """
  Repository for tag CRUD operations.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Tags.StoryTag
  alias CodeMySpec.Tags.Tag
  alias CodeMySpec.Users.Scope

  # Tag Operations

  @spec list_project_tags(Scope.t()) :: [Tag.t()]
  def list_project_tags(%Scope{active_project_id: project_id}) do
    from(t in Tag,
      where: t.project_id == ^project_id,
      order_by: [asc: t.name]
    )
    |> Repo.all()
  end

  @spec get_tag!(Scope.t(), integer()) :: Tag.t()
  def get_tag!(%Scope{active_project_id: project_id}, id) do
    Repo.get_by!(Tag, id: id, project_id: project_id)
  end

  @spec get_tag(Scope.t(), integer()) :: Tag.t() | nil
  def get_tag(%Scope{active_project_id: project_id}, id) do
    Repo.get_by(Tag, id: id, project_id: project_id)
  end

  @spec get_tag_by_name(Scope.t(), String.t()) :: Tag.t() | nil
  def get_tag_by_name(%Scope{active_project_id: project_id}, name) do
    Repo.get_by(Tag, name: name, project_id: project_id)
  end

  @spec get_or_create_tag(Scope.t(), String.t()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_tag(%Scope{active_project_id: project_id} = scope, name) do
    case get_tag_by_name(scope, name) do
      nil ->
        %Tag{}
        |> Tag.changeset(%{name: name, project_id: project_id})
        |> Repo.insert()

      tag ->
        {:ok, tag}
    end
  end

  # StoryTag Operations

  @spec create_story_tag(map()) :: {:ok, StoryTag.t()} | {:error, Ecto.Changeset.t()}
  def create_story_tag(attrs) do
    %StoryTag{}
    |> StoryTag.changeset(attrs)
    |> Repo.insert()
  end

  @spec delete_story_tag(StoryTag.t()) :: {:ok, StoryTag.t()} | {:error, Ecto.Changeset.t()}
  def delete_story_tag(%StoryTag{} = story_tag) do
    Repo.delete(story_tag)
  end

  @spec get_story_tag(integer(), integer()) :: StoryTag.t() | nil
  def get_story_tag(tag_id, story_id) do
    Repo.get_by(StoryTag, tag_id: tag_id, story_id: story_id)
  end

  @spec list_tags_for_story(Scope.t(), integer()) :: [Tag.t()]
  def list_tags_for_story(%Scope{active_project_id: project_id}, story_id) do
    from(t in Tag,
      join: st in StoryTag,
      on: st.tag_id == t.id,
      where: st.story_id == ^story_id and t.project_id == ^project_id,
      order_by: [asc: t.name]
    )
    |> Repo.all()
  end

  @spec find_stories_by_tag_id(Scope.t(), integer()) :: [Story.t()]
  def find_stories_by_tag_id(%Scope{active_project_id: project_id}, tag_id) do
    from(s in Story,
      join: st in StoryTag,
      on: st.story_id == s.id,
      where: st.tag_id == ^tag_id and s.project_id == ^project_id
    )
    |> Repo.all()
  end
end
