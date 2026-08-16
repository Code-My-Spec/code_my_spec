defmodule CodeMySpec.ContentTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ContentFixtures
  import ExUnit.CaptureLog

  alias CodeMySpec.Content

  describe "list_published_content/2 with scope" do
    test "returns only published content" do
      scope = full_scope_fixture()

      published = published_content_fixture(nil, nil, %{content_type: "blog"})
      _scheduled = scheduled_content_fixture(nil, nil, %{content_type: "blog"})
      _expired = expired_content_fixture(nil, nil, %{content_type: "blog"})

      result = Content.list_published_content(scope, :blog)

      assert length(result) == 1
      assert List.first(result).id == published.id
    end

    test "includes both public and protected content" do
      scope = full_scope_fixture()

      public = published_content_fixture(nil, nil, %{content_type: "blog", protected: false})
      protected = published_content_fixture(nil, nil, %{content_type: "blog", protected: true})

      result = Content.list_published_content(scope, :blog)

      assert length(result) == 2
      content_ids = Enum.map(result, & &1.id)
      assert public.id in content_ids
      assert protected.id in content_ids
    end

    test "filters by content_type" do
      scope = full_scope_fixture()

      blog = published_content_fixture(nil, nil, %{content_type: "blog"})
      _page = published_content_fixture(nil, nil, %{content_type: "page"})

      result = Content.list_published_content(scope, :blog)

      assert length(result) == 1
      assert List.first(result).id == blog.id
    end
  end

  describe "list_published_content/2 with nil scope" do
    test "returns only public content" do
      public = published_content_fixture(nil, nil, %{content_type: "blog", protected: false})
      _protected = published_content_fixture(nil, nil, %{content_type: "blog", protected: true})

      result = Content.list_published_content(nil, :blog)

      assert length(result) == 1
      assert List.first(result).id == public.id
      assert List.first(result).protected == false
    end

    test "excludes scheduled and expired content" do
      published = published_content_fixture(nil, nil, %{content_type: "blog", protected: false})
      _scheduled = scheduled_content_fixture(nil, nil, %{content_type: "blog", protected: false})
      _expired = expired_content_fixture(nil, nil, %{content_type: "blog", protected: false})

      result = Content.list_published_content(nil, :blog)

      assert length(result) == 1
      assert List.first(result).id == published.id
    end
  end

  describe "get_content_by_slug/3 with scope" do
    test "returns content by slug and type" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      created =
        blog_post_fixture(nil, nil, %{
          slug: "test-post",
          publish_at: yesterday
        })

      result = Content.get_content_by_slug(scope, "test-post", :blog)

      assert result.id == created.id
      assert result.slug == "test-post"
    end

    test "returns nil when content not found" do
      scope = full_scope_fixture()

      result = Content.get_content_by_slug(scope, "nonexistent", :blog)

      assert result == nil
    end

    test "returns both public and protected content" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      public =
        blog_post_fixture(nil, nil, %{
          slug: "public-post",
          publish_at: yesterday,
          protected: false
        })

      protected =
        blog_post_fixture(nil, nil, %{
          slug: "protected-post",
          publish_at: yesterday,
          protected: true
        })

      public_result = Content.get_content_by_slug(scope, "public-post", :blog)
      protected_result = Content.get_content_by_slug(scope, "protected-post", :blog)

      assert public_result.id == public.id
      assert protected_result.id == protected.id
    end
  end

  describe "get_content_by_slug/3 with nil scope" do
    test "returns only public content" do
      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      public =
        blog_post_fixture(nil, nil, %{
          slug: "public-post",
          publish_at: yesterday,
          protected: false
        })

      _protected =
        blog_post_fixture(nil, nil, %{
          slug: "protected-post",
          publish_at: yesterday,
          protected: true
        })

      public_result = Content.get_content_by_slug(nil, "public-post", :blog)
      protected_result = Content.get_content_by_slug(nil, "protected-post", :blog)

      assert public_result.id == public.id
      assert protected_result == nil
    end

    test "returns nil when content not found" do
      result = Content.get_content_by_slug(nil, "nonexistent", :blog)

      assert result == nil
    end
  end

  describe "get_content_by_slug!/3 with scope" do
    test "returns content by slug and type" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      created =
        blog_post_fixture(nil, nil, %{
          slug: "test-post",
          publish_at: yesterday
        })

      result = Content.get_content_by_slug!(scope, "test-post", :blog)

      assert result.id == created.id
    end

    test "raises when content not found" do
      scope = full_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Content.get_content_by_slug!(scope, "nonexistent", :blog)
      end
    end
  end

  describe "get_content_by_slug!/3 with nil scope" do
    test "returns nil when content not found (non-raising)" do
      result = Content.get_content_by_slug!(nil, "nonexistent", :blog)

      assert result == nil
    end

    test "returns public content" do
      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      public =
        blog_post_fixture(nil, nil, %{
          slug: "public-post",
          publish_at: yesterday,
          protected: false
        })

      result = Content.get_content_by_slug!(nil, "public-post", :blog)

      assert result.id == public.id
    end
  end

  describe "sync_content/1" do
    test "creates content from list" do
      content_list = [
        %{
          slug: "post-1",
          title: "Post 1",
          content_type: "blog",
          processed_content: "<h1>Post 1</h1>"
        },
        %{
          slug: "post-2",
          title: "Post 2",
          content_type: "blog",
          processed_content: "<h1>Post 2</h1>"
        }
      ]

      {:ok, results} = Content.sync_content(content_list)

      assert length(results) == 2
      assert Enum.all?(results, &(&1.content_type == :blog))

      slugs = Enum.map(results, & &1.slug)
      assert "post-1" in slugs
      assert "post-2" in slugs
    end

    test "deletes existing content before creating new" do
      # Create initial content
      _existing = content_fixture(nil, nil, %{slug: "existing"})

      content_list = [
        %{slug: "new", title: "New", content_type: "blog", processed_content: "<h1>New</h1>"}
      ]

      {:ok, _results} = Content.sync_content(content_list)

      # Should only have 1 content record (the new one)
      all_content = Content.list_published_content(nil, :blog)
      assert length(all_content) == 1
      assert List.first(all_content).slug == "new"
    end

    test "returns error with invalid content" do
      content_list = [
        %{slug: "valid", content_type: "blog", processed_content: "<h1>Valid</h1>"},
        %{slug: nil, content_type: "blog", processed_content: "<h1>Invalid</h1>"}
      ]

      capture_log(fn ->
        {:error, changeset} = Content.sync_content(content_list)
        assert changeset.errors[:slug]
      end)
    end

    test "rolls back transaction on error" do
      _existing = content_fixture(nil, nil, %{slug: "existing"})

      content_list = [
        %{slug: "valid", content_type: "blog", processed_content: "<h1>Valid</h1>"},
        %{slug: nil, content_type: "blog", processed_content: "<h1>Invalid</h1>"}
      ]

      capture_log(fn ->
        {:error, _} = Content.sync_content(content_list)
      end)

      # Existing content should still be there (rollback)
      scope = full_scope_fixture()
      all_content = Content.list_published_content(scope, :blog)
      assert length(all_content) == 1
      assert List.first(all_content).slug == "existing"
    end
  end

  describe "delete_all_content/0" do
    test "deletes all content" do
      _content1 = content_fixture(nil, nil)
      _content2 = content_fixture(nil, nil)

      {:ok, count} = Content.delete_all_content()

      assert count == 2

      scope = full_scope_fixture()
      assert Content.list_published_content(scope, :blog) == []
    end
  end

  describe "list_all_tags/0" do
    test "returns all tags" do
      {:ok, tag1} = Content.upsert_tag("elixir")
      {:ok, tag2} = Content.upsert_tag("phoenix")

      result = Content.list_all_tags()

      assert length(result) == 2
      tag_ids = Enum.map(result, & &1.id)
      assert tag1.id in tag_ids
      assert tag2.id in tag_ids
    end

    test "returns empty list when no tags" do
      result = Content.list_all_tags()

      assert result == []
    end
  end

  describe "upsert_tag/1" do
    test "creates new tag" do
      {:ok, tag} = Content.upsert_tag("newtag")

      assert tag.name == "newtag"
      assert tag.slug == "newtag"
    end

    test "returns existing tag on duplicate" do
      {:ok, tag1} = Content.upsert_tag("duplicate")
      {:ok, tag2} = Content.upsert_tag("duplicate")

      assert tag1.id == tag2.id
    end

    test "generates slug from name" do
      {:ok, tag} = Content.upsert_tag("Elixir Programming")

      assert tag.name == "Elixir Programming"
      assert tag.slug == "elixir-programming"
    end
  end

  describe "get_content_tags/1" do
    test "returns tags associated with content" do
      content = content_fixture(nil, nil)

      {:ok, _} = Content.sync_content_tags(content, ["elixir", "phoenix"])

      result = Content.get_content_tags(content)

      assert length(result) == 2
      tag_names = Enum.map(result, & &1.name)
      assert "elixir" in tag_names
      assert "phoenix" in tag_names
    end

    test "returns empty list when no tags" do
      content = content_fixture(nil, nil)

      result = Content.get_content_tags(content)

      assert result == []
    end
  end

  describe "sync_content_tags/2" do
    test "associates tags with content" do
      content = content_fixture(nil, nil)

      {:ok, updated} = Content.sync_content_tags(content, ["elixir", "phoenix"])

      tags = Content.get_content_tags(updated)
      assert length(tags) == 2
      tag_names = Enum.map(tags, & &1.name)
      assert "elixir" in tag_names
      assert "phoenix" in tag_names
    end

    test "removes old tags and adds new tags" do
      content = content_fixture(nil, nil)

      {:ok, _} = Content.sync_content_tags(content, ["old-tag"])
      {:ok, updated} = Content.sync_content_tags(content, ["new-tag"])

      tags = Content.get_content_tags(updated)
      assert length(tags) == 1
      assert List.first(tags).name == "new-tag"
    end

    test "removes all tags when empty list provided" do
      content = content_fixture(nil, nil)

      {:ok, _} = Content.sync_content_tags(content, ["tag1", "tag2"])
      {:ok, updated} = Content.sync_content_tags(content, [])

      tags = Content.get_content_tags(updated)
      assert tags == []
    end

    test "creates tags that don't exist" do
      content = content_fixture(nil, nil)

      {:ok, updated} = Content.sync_content_tags(content, ["brand-new-tag"])

      tags = Content.get_content_tags(updated)
      assert length(tags) == 1
      assert List.first(tags).name == "brand-new-tag"

      # Tag should now exist in system
      all_tags = Content.list_all_tags()
      assert Enum.any?(all_tags, &(&1.name == "brand-new-tag"))
    end
  end
end
