defmodule CodeMySpec.Stories.Tools.ListStoryTitlesTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary
  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "ListStoryTitles tool" do
    test "returns lightweight list of story titles" do
      scope = full_scope_fixture()
      story_fixture(scope, %{title: "First Story"})
      story_fixture(scope, %{title: "Second Story"})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "list_story_titles",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      {_, content} = response

      assert content =~ "2 stories:"
      assert content =~ "First Story"
      assert content =~ "Second Story"
    end

    test "filters by search term" do
      scope = full_scope_fixture()
      story_fixture(scope, %{title: "User Login"})
      story_fixture(scope, %{title: "User Profile"})
      story_fixture(scope, %{title: "Admin Panel"})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "list_story_titles",
          %{search: "User"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      {_, content} = response

      assert content =~ "2 stories:"
      assert content =~ "User Login"
      assert content =~ "User Profile"
      refute content =~ "Admin Panel"
    end

    test "returns sorted alphabetically by title" do
      scope = full_scope_fixture()
      story_fixture(scope, %{title: "Zebra Story"})
      story_fixture(scope, %{title: "Alpha Story"})
      story_fixture(scope, %{title: "Beta Story"})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "list_story_titles",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      {_, content} = response

      alpha_pos = :binary.match(content, "Alpha Story") |> elem(0)
      beta_pos = :binary.match(content, "Beta Story") |> elem(0)
      zebra_pos = :binary.match(content, "Zebra Story") |> elem(0)

      assert alpha_pos < beta_pos
      assert beta_pos < zebra_pos
    end

    test "returns empty state message when no stories" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "list_story_titles",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      {_, content} = response

      assert content =~ "No stories found"
    end
  end
end
