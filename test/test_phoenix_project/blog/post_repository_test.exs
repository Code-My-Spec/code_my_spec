defmodule TestPhoenixProject.Blog.PostRepositoryTest do
  use ExUnit.Case, async: true

  alias TestPhoenixProject.Blog.PostRepository

  describe "module" do
    test "exists" do
      assert Code.ensure_loaded?(PostRepository)
    end

    test "exports expected CRUD functions" do
      assert function_exported?(PostRepository, :list_posts, 1)
      assert function_exported?(PostRepository, :get_post!, 2)
      assert function_exported?(PostRepository, :create_post, 2)
      assert function_exported?(PostRepository, :update_post, 3)
      assert function_exported?(PostRepository, :delete_post, 2)
      assert function_exported?(PostRepository, :change_post, 3)
    end

    test "does not export unexpected functions" do
      exports =
        PostRepository.__info__(:functions)
        |> Keyword.keys()
        |> Enum.uniq()

      expected = [:list_posts, :get_post!, :create_post, :update_post, :delete_post, :change_post]
      assert Enum.sort(exports) == Enum.sort(expected)
    end
  end
end
