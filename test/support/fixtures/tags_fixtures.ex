defmodule CodeMySpec.TagsFixtures do
  @moduledoc """
  Test data for `CodeMySpec.Tags`.
  """

  alias CodeMySpec.Repo
  alias CodeMySpec.Tags
  alias CodeMySpec.Tags.StoryTag
  alias CodeMySpec.Tags.Tag

  @doc """
  Generate a tag with valid attributes.
  """
  def tag_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "tag-#{System.unique_integer([:positive])}"
      })

    {:ok, tag} = Tags.get_or_create_tag(scope, attrs.name)
    tag
  end

  @doc """
  Generate multiple tags for a project.
  """
  def multiple_tags_fixture(scope, count \\ 3) do
    Enum.map(1..count, fn i ->
      tag_fixture(scope, %{name: "test-tag-#{i}"})
    end)
  end

  @doc """
  Add a tag to a story.
  """
  def story_tagging_fixture(scope, story, tag_name \\ nil) do
    tag_name = tag_name || "story-tag-#{System.unique_integer([:positive])}"
    {:ok, story_tag} = Tags.add_tag(scope, story, tag_name)
    story_tag
  end

  @doc """
  Valid attributes for creating a tag.
  """
  def valid_tag_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "valid-tag-#{System.unique_integer([:positive])}"
    })
  end

  @doc """
  Invalid attributes for creating a tag (invalid format).
  """
  def invalid_tag_attrs do
    %{name: "invalid tag with spaces!"}
  end

  @doc """
  Create a tag directly via Repo (bypasses context for testing repository layer).
  """
  def raw_tag_fixture(project_id, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "raw-tag-#{System.unique_integer([:positive])}",
        project_id: project_id
      })

    %Tag{}
    |> Tag.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Create a story tag directly via Repo (bypasses context for testing repository layer).
  """
  def raw_story_tag_fixture(tag, story) do
    attrs = %{
      tag_id: tag.id,
      story_id: story.id
    }

    %StoryTag{}
    |> StoryTag.changeset(attrs)
    |> Repo.insert!()
  end
end
