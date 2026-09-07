defmodule CodeMySpec.Content.TagRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Content.{Tag, TagRepository}
  alias CodeMySpec.Repo

  describe "upsert_tag/1" do
    test "creates new tag with normalized name and slug" do
      assert {:ok, tag} = TagRepository.upsert_tag("New Tag")

      assert tag.name == "New Tag"
      assert tag.slug == "new-tag"

      persisted = Repo.get!(Tag, tag.id)
      assert persisted.name == "New Tag"
      assert persisted.slug == "new-tag"
    end

    test "normalizes uppercase names" do
      assert {:ok, tag} = TagRepository.upsert_tag("UPPERCASE TAG")

      assert tag.name == "UPPERCASE TAG"
      assert tag.slug == "uppercase-tag"
    end

    test "normalizes mixed case names" do
      assert {:ok, tag} = TagRepository.upsert_tag("MiXeD CaSe TaG")

      assert tag.name == "MiXeD CaSe TaG"
      assert tag.slug == "mixed-case-tag"
    end

    test "generates URL-safe slug from special characters" do
      assert {:ok, tag} = TagRepository.upsert_tag("Tag with Special-Chars & Symbols!")

      assert tag.name == "Tag with Special-Chars & Symbols!"
      assert tag.slug == "tag-with-special-chars-symbols"
    end

    test "returns existing tag when slug already exists globally" do
      {:ok, original_tag} = TagRepository.upsert_tag("Existing Tag")
      {:ok, returned_tag} = TagRepository.upsert_tag("Existing Tag")

      assert returned_tag.id == original_tag.id
      assert returned_tag.name == original_tag.name
      assert returned_tag.slug == original_tag.slug
    end

    test "returns existing tag when different case matches existing slug" do
      {:ok, original_tag} = TagRepository.upsert_tag("duplicate")
      {:ok, returned_tag} = TagRepository.upsert_tag("DUPLICATE")

      assert returned_tag.id == original_tag.id
      assert returned_tag.slug == "duplicate"
    end

    test "enforces global uniqueness - same slug cannot exist twice" do
      {:ok, tag1} = TagRepository.upsert_tag("Shared Tag")
      {:ok, tag2} = TagRepository.upsert_tag("Shared Tag")

      # Should return the same tag
      assert tag1.id == tag2.id
      assert tag1.slug == tag2.slug

      # Verify only one tag exists in database
      all_tags = Repo.all(Tag)
      matching_tags = Enum.filter(all_tags, &(&1.slug == "shared-tag"))
      assert length(matching_tags) == 1
    end

    test "returns error for invalid tag name" do
      assert {:error, changeset} = TagRepository.upsert_tag("")
      assert "can't be blank" in errors_on(changeset).name
    end

    test "returns error for tag name exceeding max length" do
      long_name = String.duplicate("a", 51)

      assert {:error, changeset} = TagRepository.upsert_tag(long_name)
      assert "should be at most 50 character(s)" in errors_on(changeset).name
    end

    test "handles tag name at max length boundary" do
      max_length_name = String.duplicate("a", 50)

      assert {:ok, tag} = TagRepository.upsert_tag(max_length_name)
      assert String.length(tag.name) == 50
    end
  end

  describe "list_tags/0" do
    test "returns all tags ordered alphabetically" do
      {:ok, tag_c} = TagRepository.upsert_tag("charlie")
      {:ok, tag_a} = TagRepository.upsert_tag("alpha")
      {:ok, tag_b} = TagRepository.upsert_tag("bravo")

      tags = TagRepository.list_tags()

      assert length(tags) == 3
      assert Enum.map(tags, & &1.slug) == ["alpha", "bravo", "charlie"]
      assert Enum.map(tags, & &1.id) == [tag_a.id, tag_b.id, tag_c.id]
    end

    test "returns empty list when no tags exist" do
      tags = TagRepository.list_tags()

      assert tags == []
    end

    test "returns all tags globally - no scoping" do
      {:ok, tag1} = TagRepository.upsert_tag("Tag One")
      {:ok, tag2} = TagRepository.upsert_tag("Tag Two")
      {:ok, tag3} = TagRepository.upsert_tag("Tag Three")

      tags = TagRepository.list_tags()

      assert length(tags) == 3
      tag_ids = Enum.map(tags, & &1.id) |> Enum.sort()
      expected_ids = [tag1.id, tag2.id, tag3.id] |> Enum.sort()
      assert tag_ids == expected_ids
    end
  end

  describe "get_tag_by_slug/1" do
    test "returns tag when slug exists" do
      {:ok, created_tag} = TagRepository.upsert_tag("Test Tag")

      tag = TagRepository.get_tag_by_slug("test-tag")

      assert tag.id == created_tag.id
      assert tag.name == "Test Tag"
      assert tag.slug == "test-tag"
    end

    test "returns nil when slug does not exist" do
      tag = TagRepository.get_tag_by_slug("nonexistent")

      assert tag == nil
    end

    test "returns tag globally - no scoping" do
      {:ok, created_tag} = TagRepository.upsert_tag("Global Tag")

      tag = TagRepository.get_tag_by_slug("global-tag")

      assert tag.id == created_tag.id
      assert tag.slug == "global-tag"
    end
  end

  describe "get_tag_by_slug!/1" do
    test "returns tag when slug exists" do
      {:ok, created_tag} = TagRepository.upsert_tag("Test Tag")

      tag = TagRepository.get_tag_by_slug!("test-tag")

      assert tag.id == created_tag.id
      assert tag.name == "Test Tag"
    end

    test "raises Ecto.NoResultsError when slug does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        TagRepository.get_tag_by_slug!("nonexistent")
      end
    end
  end

  describe "by_slug/2" do
    test "filters query by slug" do
      {:ok, tag1} = TagRepository.upsert_tag("Target Tag")
      {:ok, _tag2} = TagRepository.upsert_tag("Other Tag")

      query = Tag |> TagRepository.by_slug("target-tag")
      results = Repo.all(query)

      assert length(results) == 1
      assert List.first(results).id == tag1.id
    end

    test "returns empty result when slug does not exist" do
      {:ok, _tag} = TagRepository.upsert_tag("Existing Tag")

      query = Tag |> TagRepository.by_slug("nonexistent")
      results = Repo.all(query)

      assert results == []
    end

    test "can be composed with other query functions" do
      {:ok, tag1} = TagRepository.upsert_tag("Alpha")
      {:ok, _tag2} = TagRepository.upsert_tag("Bravo")

      import Ecto.Query

      query =
        Tag
        |> TagRepository.by_slug("alpha")
        |> where([t], t.name == "Alpha")

      results = Repo.all(query)

      assert length(results) == 1
      assert List.first(results).id == tag1.id
    end
  end
end
