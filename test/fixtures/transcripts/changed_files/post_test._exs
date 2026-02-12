defmodule TestPhoenixProject.Blog.PostTest do
  use ExUnit.Case, async: true

  alias TestPhoenixProject.Blog.Post

  describe "title_slug/1" do
    test "converts title to lowercase hyphenated slug" do
      post = %Post{title: "My First Post"}
      assert Post.title_slug(post) == "my-first-post"
    end

    test "handles consecutive spaces" do
      post = %Post{title: "Hello   World"}
      assert Post.title_slug(post) == "hello-world"
    end

    test "handles already lowercase single word" do
      post = %Post{title: "hello"}
      assert Post.title_slug(post) == "hello"
    end
  end
end
