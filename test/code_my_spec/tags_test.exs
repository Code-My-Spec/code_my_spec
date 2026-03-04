defmodule CodeMySpec.TagsTest do
  use CodeMySpecTest.DataCase

  alias CodeMySpec.Tags
  alias CodeMySpec.Tags.Tag

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.TagsFixtures

  describe "add_tag/3" do
    test "creates tag if it doesn't exist" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:ok, story_tag} = Tags.add_tag(scope, story, "new-tag")
      story_tag = CodeMySpec.Repo.preload(story_tag, :tag)
      assert story_tag.tag.name == "new-tag"

      # Verify tag was created
      tags = Tags.list_project_tags(scope)
      assert Enum.any?(tags, &(&1.name == "new-tag"))
    end

    test "creates story_tag association" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, story_tag} = Tags.add_tag(scope, story, "story-tag")

      assert story_tag.story_id == story.id
      assert story_tag.tag_id != nil
    end

    test "returns error for duplicate (idempotent)" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _story_tag1} = Tags.add_tag(scope, story, "dupe-tag")
      {:error, changeset} = Tags.add_tag(scope, story, "dupe-tag")

      assert changeset.errors[:tag_id] || changeset.errors[:story_id]
    end

    test "scopes operations to project" do
      scope1 = full_scope_fixture()
      scope2 = full_scope_fixture()

      story1 = story_fixture(scope1)
      story2 = story_fixture(scope2)

      {:ok, _} = Tags.add_tag(scope1, story1, "project-tag")
      {:ok, _} = Tags.add_tag(scope2, story2, "project-tag")

      # Each project has its own tag
      tags1 = Tags.list_project_tags(scope1)
      tags2 = Tags.list_project_tags(scope2)

      assert length(tags1) == 1
      assert length(tags2) == 1
      assert hd(tags1).id != hd(tags2).id
    end
  end

  describe "remove_tag/3" do
    test "removes existing tagging" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _} = Tags.add_tag(scope, story, "remove-tag")
      assert :ok = Tags.remove_tag(scope, story, "remove-tag")

      tags = Tags.list_story_tags(scope, story)
      assert Enum.empty?(tags)
    end

    test "returns :not_found for non-existent tagging" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:error, :not_found} = Tags.remove_tag(scope, story, "nonexistent-tag")
    end

    test "does not delete the tag itself" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, story_tag} = Tags.add_tag(scope, story, "keep-tag")
      tag_id = story_tag.tag_id

      :ok = Tags.remove_tag(scope, story, "keep-tag")

      # Tag should still exist
      assert Tags.get_tag(scope, tag_id) != nil
    end
  end

  describe "list_story_tags/2" do
    test "returns all tags for a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _} = Tags.add_tag(scope, story, "tag-a")
      {:ok, _} = Tags.add_tag(scope, story, "tag-b")
      {:ok, _} = Tags.add_tag(scope, story, "tag-c")

      tags = Tags.list_story_tags(scope, story)

      assert length(tags) == 3
      tag_names = Enum.map(tags, & &1.name)
      assert "tag-a" in tag_names
      assert "tag-b" in tag_names
      assert "tag-c" in tag_names
    end

    test "returns empty list when no tags exist" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      tags = Tags.list_story_tags(scope, story)
      assert Enum.empty?(tags)
    end
  end

  describe "find_stories_by_tag/2" do
    test "returns stories with the given tag" do
      scope = full_scope_fixture()
      story1 = story_fixture(scope, %{title: "Story 1"})
      story2 = story_fixture(scope, %{title: "Story 2"})
      _story3 = story_fixture(scope, %{title: "Story 3"})

      {:ok, _} = Tags.add_tag(scope, story1, "find-tag")
      {:ok, _} = Tags.add_tag(scope, story2, "find-tag")

      stories = Tags.find_stories_by_tag(scope, "find-tag")

      assert length(stories) == 2
      story_ids = Enum.map(stories, & &1.id)
      assert story1.id in story_ids
      assert story2.id in story_ids
    end

    test "returns empty list for unknown tag" do
      scope = full_scope_fixture()

      result = Tags.find_stories_by_tag(scope, "unknown-tag")
      assert Enum.empty?(result)
    end

    test "returns empty list when no stories have the tag" do
      scope = full_scope_fixture()

      # Create tag but don't assign it to anything
      tag_fixture(scope, %{name: "orphan-tag"})

      result = Tags.find_stories_by_tag(scope, "orphan-tag")
      assert Enum.empty?(result)
    end
  end

  describe "list_project_tags/1" do
    test "returns all tags for a project" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _} = Tags.add_tag(scope, story, "project-tag-1")
      {:ok, _} = Tags.add_tag(scope, story, "project-tag-2")

      tags = Tags.list_project_tags(scope)

      assert length(tags) == 2
      tag_names = Enum.map(tags, & &1.name)
      assert "project-tag-1" in tag_names
      assert "project-tag-2" in tag_names
    end

    test "returns tags ordered by name" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _} = Tags.add_tag(scope, story, "zebra")
      {:ok, _} = Tags.add_tag(scope, story, "alpha")
      {:ok, _} = Tags.add_tag(scope, story, "beta")

      tags = Tags.list_project_tags(scope)
      tag_names = Enum.map(tags, & &1.name)

      assert tag_names == ["alpha", "beta", "zebra"]
    end
  end

  describe "get_or_create_tag/2" do
    test "creates a new tag if it doesn't exist" do
      scope = full_scope_fixture()

      {:ok, tag} = Tags.get_or_create_tag(scope, "new-tag")

      assert tag.name == "new-tag"
      assert tag.project_id == scope.active_project_id
    end

    test "returns existing tag if it exists" do
      scope = full_scope_fixture()

      {:ok, tag1} = Tags.get_or_create_tag(scope, "existing-tag")
      {:ok, tag2} = Tags.get_or_create_tag(scope, "existing-tag")

      assert tag1.id == tag2.id
    end
  end

  describe "get_tag!/2" do
    test "returns tag by id" do
      scope = full_scope_fixture()
      {:ok, created_tag} = Tags.get_or_create_tag(scope, "get-test-tag")

      fetched_tag = Tags.get_tag!(scope, created_tag.id)

      assert fetched_tag.id == created_tag.id
      assert fetched_tag.name == "get-test-tag"
    end

    test "raises for non-existent tag" do
      scope = full_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Tags.get_tag!(scope, -1)
      end
    end
  end

  describe "sync_tags/3" do
    test "adds missing tags" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _story} = Tags.sync_tags(scope, story, ["tag-a", "tag-b"])

      tags = Tags.list_story_tags(scope, story)
      tag_names = Enum.map(tags, & &1.name)
      assert Enum.sort(tag_names) == ["tag-a", "tag-b"]
    end

    test "removes extra tags" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _} = Tags.add_tag(scope, story, "keep")
      {:ok, _} = Tags.add_tag(scope, story, "remove-me")

      {:ok, _story} = Tags.sync_tags(scope, story, ["keep"])

      tags = Tags.list_story_tags(scope, story)
      tag_names = Enum.map(tags, & &1.name)
      assert tag_names == ["keep"]
    end

    test "is idempotent when tags match" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _} = Tags.add_tag(scope, story, "already-there")

      {:ok, _story} = Tags.sync_tags(scope, story, ["already-there"])

      tags = Tags.list_story_tags(scope, story)
      assert length(tags) == 1
      assert hd(tags).name == "already-there"
    end

    test "clears all tags when given empty list" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _} = Tags.add_tag(scope, story, "clear-me")
      {:ok, _} = Tags.add_tag(scope, story, "clear-me-too")

      {:ok, _story} = Tags.sync_tags(scope, story, [])

      tags = Tags.list_story_tags(scope, story)
      assert Enum.empty?(tags)
    end

    test "handles mixed add and remove" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, _} = Tags.add_tag(scope, story, "keep")
      {:ok, _} = Tags.add_tag(scope, story, "old")

      {:ok, _story} = Tags.sync_tags(scope, story, ["keep", "new"])

      tags = Tags.list_story_tags(scope, story)
      tag_names = Enum.map(tags, & &1.name)
      assert Enum.sort(tag_names) == ["keep", "new"]
    end
  end

  describe "Tag schema validation" do
    test "validates name format" do
      scope = full_scope_fixture()

      # Valid formats
      assert {:ok, _} = Tags.get_or_create_tag(scope, "valid-tag")
      assert {:ok, _} = Tags.get_or_create_tag(scope, "valid_tag")
      assert {:ok, _} = Tags.get_or_create_tag(scope, "valid.tag")
      assert {:ok, _} = Tags.get_or_create_tag(scope, "valid:tag")
      assert {:ok, _} = Tags.get_or_create_tag(scope, "ValidTag123")

      # Invalid format - direct changeset test
      changeset =
        Tag.changeset(%Tag{}, %{name: "invalid tag!", project_id: scope.active_project_id})

      refute changeset.valid?
      assert changeset.errors[:name]
    end
  end
end
