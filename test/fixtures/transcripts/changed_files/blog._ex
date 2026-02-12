defmodule TestPhoenixProject.Blog do
  @moduledoc """
  Provides scoped operations for managing blog posts with real-time PubSub notifications.
  """

  import Ecto.Query, warn: false

  alias TestPhoenixProject.Blog.Post
  alias TestPhoenixProject.Accounts.Scope
  alias TestPhoenixProject.Blog.PostRepository

  @doc """
  Subscribes to scoped notifications about any post changes.

  The broadcasted messages match the pattern:

    * {:created, %Post{}}
    * {:updated, %Post{}}
    * {:deleted, %Post{}}

  """
  def subscribe_posts(%Scope{} = scope) do
    key = scope.user.id

    Phoenix.PubSub.subscribe(TestPhoenixProject.PubSub, "user:#{key}:posts")
  end

  defp broadcast_post(%Scope{} = scope, message) do
    key = scope.user.id

    Phoenix.PubSub.broadcast(TestPhoenixProject.PubSub, "user:#{key}:posts", message)
  end

  defdelegate list_posts(scope), to: PostRepository
  defdelegate get_post!(scope, id), to: PostRepository
  defdelegate change_post(scope, post, attrs \\ %{}), to: PostRepository

  def create_post(scope, attrs) do
    with {:ok, post = %Post{}} <- PostRepository.create_post(scope, attrs) do
      broadcast_post(scope, {:created, post})
      {:ok, post}
    end
  end

  def update_post(%Scope{} = scope, %Post{} = post, attrs) do
    true = post.user_id == scope.user.id

    with {:ok, post = %Post{}} <- PostRepository.update_post(scope, post, attrs) do
      broadcast_post(scope, {:updated, post})
      {:ok, post}
    end
  end

  def delete_post(scope, post) do
    true = post.user_id == scope.user.id

    with {:ok, post = %Post{}} <- PostRepository.delete_post(scope, post) do
      broadcast_post(scope, {:deleted, post})
      {:ok, post}
    end
  end
end
