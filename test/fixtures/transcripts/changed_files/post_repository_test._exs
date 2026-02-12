defmodule TestPhoenixProject.Blog.PostRepositoryTest do
  use TestPhoenixProject.DataCase, async: true

  alias TestPhoenixProject.Blog.PostRepository
  alias TestPhoenixProject.Blog.Post

  import TestPhoenixProject.AccountsFixtures, only: [user_scope_fixture: 0]
  import TestPhoenixProject.BlogFixtures

  @invalid_attrs %{title: nil, content: nil, published: nil}

  describe "list_posts/1" do
    test "returns all posts for scoped user" do
      scope = user_scope_fixture()
      post1 = post_fixture(scope)
      post2 = post_fixture(scope)
      assert PostRepository.list_posts(scope) == [post1, post2]
    end

    test "returns empty list when user has no posts" do
      scope = user_scope_fixture()
      assert PostRepository.list_posts(scope) == []
    end

    test "does not return posts from other users" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()

      _post_for_scope = post_fixture(scope)
      _post_for_other = post_fixture(other_scope)

      posts = PostRepository.list_posts(scope)
      assert length(posts) == 1
      assert Enum.all?(posts, fn post -> post.user_id == scope.user.id end)
    end
  end

  describe "get_post!/2" do
    test "returns post when found and owned by scoped user" do
      scope = user_scope_fixture()
      post = post_fixture(scope)
      assert PostRepository.get_post!(scope, post.id) == post
    end

    test "raises Ecto.NoResultsError when post not found" do
      scope = user_scope_fixture()
      assert_raise Ecto.NoResultsError, fn ->
        PostRepository.get_post!(scope, 999999)
      end
    end

    test "raises Ecto.NoResultsError when post owned by different user" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      post = post_fixture(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        PostRepository.get_post!(scope, post.id)
      end
    end
  end

  describe "create_post/2" do
    test "creates post with valid attributes" do
      scope = user_scope_fixture()
      valid_attrs = %{title: "some title", content: "some content", published: true}

      assert {:ok, %Post{} = post} = PostRepository.create_post(scope, valid_attrs)
      assert post.title == "some title"
      assert post.content == "some content"
      assert post.published == true
    end

    test "sets user_id from scope" do
      scope = user_scope_fixture()
      valid_attrs = %{title: "title", content: "content", published: true}

      assert {:ok, %Post{} = post} = PostRepository.create_post(scope, valid_attrs)
      assert post.user_id == scope.user.id
    end

    test "returns error changeset for invalid attributes" do
      scope = user_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = PostRepository.create_post(scope, @invalid_attrs)
    end

    test "validates required fields" do
      scope = user_scope_fixture()
      {:error, changeset} = PostRepository.create_post(scope, %{})

      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "update_post/3" do
    test "updates post with valid attributes" do
      scope = user_scope_fixture()
      post = post_fixture(scope)
      update_attrs = %{title: "updated title", content: "updated content"}

      assert {:ok, %Post{} = updated_post} = PostRepository.update_post(scope, post, update_attrs)
      assert updated_post.title == "updated title"
      assert updated_post.content == "updated content"
    end

    test "returns error changeset for invalid attributes" do
      scope = user_scope_fixture()
      post = post_fixture(scope)

      assert {:error, %Ecto.Changeset{}} = PostRepository.update_post(scope, post, @invalid_attrs)
    end

    test "raises MatchError when user does not own post" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      post = post_fixture(other_scope)

      assert_raise MatchError, fn ->
        PostRepository.update_post(scope, post, %{title: "new title"})
      end
    end
  end

  describe "delete_post/2" do
    test "deletes post when user owns it" do
      scope = user_scope_fixture()
      post = post_fixture(scope)

      assert {:ok, %Post{}} = PostRepository.delete_post(scope, post)
      assert_raise Ecto.NoResultsError, fn ->
        PostRepository.get_post!(scope, post.id)
      end
    end

    test "raises MatchError when user does not own post" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      post = post_fixture(other_scope)

      assert_raise MatchError, fn ->
        PostRepository.delete_post(scope, post)
      end
    end
  end

  describe "change_post/3" do
    test "returns changeset for post" do
      scope = user_scope_fixture()
      post = post_fixture(scope)

      assert %Ecto.Changeset{} = PostRepository.change_post(scope, post)
    end

    test "includes validation errors in changeset" do
      scope = user_scope_fixture()
      post = post_fixture(scope)

      changeset = PostRepository.change_post(scope, post, @invalid_attrs)
      assert %Ecto.Changeset{} = changeset
      refute changeset.valid?
    end
  end
end
