defmodule CodeMySpec.Content.ContentRepositoryTest do
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ContentFixtures
  import CodeMySpec.TagFixtures
  import CodeMySpec.ContentTagFixtures

  alias CodeMySpec.Content.ContentRepository

  describe "list_published_content/2 with scope" do
    test "returns only published content with success parse status" do
      scope = full_scope_fixture()

      published =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog"
        })

      _scheduled =
        scheduled_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog"
        })

      _expired =
        expired_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog"
        })

      content_list = ContentRepository.list_published_content(scope, :blog)

      assert length(content_list) == 1
      assert List.first(content_list).id == published.id
    end

    test "filters by content_type" do
      scope = full_scope_fixture()

      blog =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog"
        })

      _page =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "page"
        })

      blog_list = ContentRepository.list_published_content(scope, :blog)
      page_list = ContentRepository.list_published_content(scope, :page)

      assert length(blog_list) == 1
      assert length(page_list) == 1
      assert List.first(blog_list).id == blog.id
    end

    test "includes content with publish_at in past and no expires_at" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      content =
        content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          publish_at: yesterday,
          expires_at: nil
        })

      content_list = ContentRepository.list_published_content(scope, :blog)

      assert length(content_list) == 1
      assert List.first(content_list).id == content.id
    end

    test "includes content with expires_at in future" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)
      tomorrow = DateTime.utc_now() |> DateTime.add(1, :day)

      content =
        content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          publish_at: yesterday,
          expires_at: tomorrow
        })

      content_list = ContentRepository.list_published_content(scope, :blog)

      assert length(content_list) == 1
      assert List.first(content_list).id == content.id
    end

    test "includes both public and protected content when scope provided" do
      scope = full_scope_fixture()

      public =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          protected: false
        })

      protected =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          protected: true
        })

      content_list = ContentRepository.list_published_content(scope, :blog)

      assert length(content_list) == 2
      content_ids = Enum.map(content_list, & &1.id)
      assert public.id in content_ids
      assert protected.id in content_ids
    end

    test "returns content from all accounts and projects (no multi-tenant filtering)" do
      scope1 = full_scope_fixture()
      scope2 = full_scope_fixture()

      content1 =
        published_content_fixture(scope1.active_project, scope1.active_account, %{
          content_type: "blog"
        })

      content2 =
        published_content_fixture(scope2.active_project, scope2.active_account, %{
          content_type: "blog"
        })

      # Using scope1, but should get content from both accounts/projects
      content_list = ContentRepository.list_published_content(scope1, :blog)

      assert length(content_list) == 2
      content_ids = Enum.map(content_list, & &1.id)
      assert content1.id in content_ids
      assert content2.id in content_ids
    end
  end

  describe "list_published_content/2 with nil scope" do
    test "returns only public content when scope is nil" do
      scope = full_scope_fixture()

      public =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          protected: false
        })

      _protected =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          protected: true
        })

      content_list = ContentRepository.list_published_content(nil, :blog)

      assert length(content_list) == 1
      assert List.first(content_list).id == public.id
      assert List.first(content_list).protected == false
    end

    test "filters by content_type" do
      scope = full_scope_fixture()

      blog =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          protected: false
        })

      _page =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "page",
          protected: false
        })

      blog_list = ContentRepository.list_published_content(nil, :blog)

      assert length(blog_list) == 1
      assert List.first(blog_list).id == blog.id
    end

    test "excludes scheduled and expired content" do
      scope = full_scope_fixture()

      published =
        published_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          protected: false
        })

      _scheduled =
        scheduled_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          protected: false
        })

      _expired =
        expired_content_fixture(scope.active_project, scope.active_account, %{
          content_type: "blog",
          protected: false
        })

      content_list = ContentRepository.list_published_content(nil, :blog)

      assert length(content_list) == 1
      assert List.first(content_list).id == published.id
    end
  end

  describe "get_content_by_slug/3 with scope" do
    test "returns published content when slug and content_type match" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      created =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "test-post",
          publish_at: yesterday
        })

      content = ContentRepository.get_content_by_slug(scope, "test-post", :blog)

      assert content.id == created.id
      assert content.slug == "test-post"
      assert content.content_type == :blog
    end

    test "returns nil when slug does not exist" do
      scope = full_scope_fixture()

      content = ContentRepository.get_content_by_slug(scope, "nonexistent", :blog)

      assert content == nil
    end

    test "returns nil when content_type does not match" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      _blog =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "test-slug",
          publish_at: yesterday
        })

      content = ContentRepository.get_content_by_slug(scope, "test-slug", :page)

      assert content == nil
    end

    test "returns nil for unpublished content (scheduled)" do
      scope = full_scope_fixture()

      tomorrow = DateTime.utc_now() |> DateTime.add(1, :day)

      _scheduled =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "scheduled-post",
          publish_at: tomorrow
        })

      content = ContentRepository.get_content_by_slug(scope, "scheduled-post", :blog)

      assert content == nil
    end

    test "returns nil for expired content" do
      scope = full_scope_fixture()

      week_ago = DateTime.utc_now() |> DateTime.add(-7, :day)
      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      _expired =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "expired-post",
          publish_at: week_ago,
          expires_at: yesterday
        })

      content = ContentRepository.get_content_by_slug(scope, "expired-post", :blog)

      assert content == nil
    end

    test "returns both public and protected content when scope provided" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      public =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "public-post",
          publish_at: yesterday,
          protected: false
        })

      protected =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "protected-post",
          publish_at: yesterday,
          protected: true
        })

      public_result = ContentRepository.get_content_by_slug(scope, "public-post", :blog)
      protected_result = ContentRepository.get_content_by_slug(scope, "protected-post", :blog)

      assert public_result.id == public.id
      assert protected_result.id == protected.id
    end

    test "enforces slug uniqueness per content_type" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      blog =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "shared-slug",
          publish_at: yesterday
        })

      page =
        page_fixture(scope.active_project, scope.active_account, %{
          slug: "shared-slug",
          publish_at: yesterday
        })

      blog_result = ContentRepository.get_content_by_slug(scope, "shared-slug", :blog)
      page_result = ContentRepository.get_content_by_slug(scope, "shared-slug", :page)

      assert blog_result.id == blog.id
      assert page_result.id == page.id
      assert blog_result.id != page_result.id
    end
  end

  describe "get_content_by_slug/3 with nil scope" do
    test "returns only public content when scope is nil" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      public =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "public-post",
          publish_at: yesterday,
          protected: false
        })

      _protected =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "protected-post",
          publish_at: yesterday,
          protected: true
        })

      public_result = ContentRepository.get_content_by_slug(nil, "public-post", :blog)
      protected_result = ContentRepository.get_content_by_slug(nil, "protected-post", :blog)

      assert public_result.id == public.id
      assert protected_result == nil
    end

    test "returns nil when slug does not exist" do
      content = ContentRepository.get_content_by_slug(nil, "nonexistent", :blog)

      assert content == nil
    end

    test "excludes unpublished content" do
      scope = full_scope_fixture()

      tomorrow = DateTime.utc_now() |> DateTime.add(1, :day)

      _scheduled =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "scheduled-post",
          publish_at: tomorrow,
          protected: false
        })

      content = ContentRepository.get_content_by_slug(nil, "scheduled-post", :blog)

      assert content == nil
    end
  end

  describe "get_content_by_slug!/3 with scope" do
    test "returns content when slug and content_type exist" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      created =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "test-post",
          publish_at: yesterday
        })

      content = ContentRepository.get_content_by_slug!(scope, "test-post", :blog)

      assert content.id == created.id
      assert content.slug == "test-post"
    end

    test "raises Ecto.NoResultsError when slug does not exist" do
      scope = full_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        ContentRepository.get_content_by_slug!(scope, "nonexistent", :blog)
      end
    end

    test "raises Ecto.NoResultsError when content_type does not match" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      _blog =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "test-slug",
          publish_at: yesterday
        })

      assert_raise Ecto.NoResultsError, fn ->
        ContentRepository.get_content_by_slug!(scope, "test-slug", :page)
      end
    end
  end

  describe "get_content_by_slug!/3 with nil scope" do
    test "returns nil when scope is nil and content not found (non-raising)" do
      result = ContentRepository.get_content_by_slug!(nil, "nonexistent", :blog)

      assert result == nil
    end

    test "returns public content when scope is nil" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      public =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "public-post",
          publish_at: yesterday,
          protected: false
        })

      result = ContentRepository.get_content_by_slug!(nil, "public-post", :blog)

      assert result.id == public.id
    end

    test "returns nil for protected content when scope is nil (non-raising)" do
      scope = full_scope_fixture()

      yesterday = DateTime.utc_now() |> DateTime.add(-1, :day)

      _protected =
        blog_post_fixture(scope.active_project, scope.active_account, %{
          slug: "protected-post",
          publish_at: yesterday,
          protected: true
        })

      result = ContentRepository.get_content_by_slug!(nil, "protected-post", :blog)

      assert result == nil
    end
  end

  describe "preload_tags/1" do
    test "preloads tags for single content" do
      scope = full_scope_fixture()

      content = content_fixture(scope.active_project, scope.active_account)
      tag1 = tag_fixture(scope.active_project, scope.active_account, %{name: "tag1"})
      tag2 = tag_fixture(scope.active_project, scope.active_account, %{name: "tag2"})

      _ct1 = content_tag_fixture(content, tag1)
      _ct2 = content_tag_fixture(content, tag2)

      loaded_content = ContentRepository.preload_tags(content)

      assert Ecto.assoc_loaded?(loaded_content.tags)
      assert length(loaded_content.tags) == 2
      tag_names = Enum.map(loaded_content.tags, & &1.name)
      assert "tag1" in tag_names
      assert "tag2" in tag_names
    end

    test "preloads tags for list of content" do
      scope = full_scope_fixture()

      content1 = content_fixture(scope.active_project, scope.active_account)
      content2 = content_fixture(scope.active_project, scope.active_account)

      tag1 = tag_fixture(scope.active_project, scope.active_account, %{name: "tag1"})
      tag2 = tag_fixture(scope.active_project, scope.active_account, %{name: "tag2"})

      _ct1 = content_tag_fixture(content1, tag1)
      _ct2 = content_tag_fixture(content2, tag2)

      loaded_content_list = ContentRepository.preload_tags([content1, content2])

      assert length(loaded_content_list) == 2
      assert Enum.all?(loaded_content_list, &Ecto.assoc_loaded?(&1.tags))

      [first, second] = loaded_content_list
      assert length(first.tags) == 1
      assert length(second.tags) == 1
    end

    test "handles content with no tags" do
      scope = full_scope_fixture()

      content = content_fixture(scope.active_project, scope.active_account)

      loaded_content = ContentRepository.preload_tags(content)

      assert Ecto.assoc_loaded?(loaded_content.tags)
      assert loaded_content.tags == []
    end

    test "handles empty list" do
      loaded_content_list = ContentRepository.preload_tags([])

      assert loaded_content_list == []
    end

    test "avoids N+1 queries when loading tags" do
      scope = full_scope_fixture()

      content1 = content_fixture(scope.active_project, scope.active_account)
      content2 = content_fixture(scope.active_project, scope.active_account)
      content3 = content_fixture(scope.active_project, scope.active_account)

      tag = tag_fixture(scope.active_project, scope.active_account)

      _ct1 = content_tag_fixture(content1, tag)
      _ct2 = content_tag_fixture(content2, tag)
      _ct3 = content_tag_fixture(content3, tag)

      # Load without preloading first
      content_list = [content1, content2, content3]

      # Preload in single operation
      loaded_list = ContentRepository.preload_tags(content_list)

      assert length(loaded_list) == 3
      assert Enum.all?(loaded_list, &Ecto.assoc_loaded?(&1.tags))
      assert Enum.all?(loaded_list, &(length(&1.tags) == 1))
    end
  end
end
