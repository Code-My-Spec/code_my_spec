defmodule CodeMySpec.McpServers.Stories.Tools.ListStoryTitlesTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.McpServers.Stories.Tools.ListStoryTitles
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "ListStoryTitles tool" do
    test "returns lightweight list of story titles" do
      scope = full_scope_fixture()
      story_fixture(scope, %{title: "First Story"})
      story_fixture(scope, %{title: "Second Story"})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListStoryTitles.execute(%{}, frame)
      assert response.type == :tool

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

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

      assert {:reply, response, ^frame} = ListStoryTitles.execute(%{search: "User"}, frame)

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

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

      assert {:reply, response, ^frame} = ListStoryTitles.execute(%{}, frame)

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      alpha_pos = :binary.match(content, "Alpha Story") |> elem(0)
      beta_pos = :binary.match(content, "Beta Story") |> elem(0)
      zebra_pos = :binary.match(content, "Zebra Story") |> elem(0)

      assert alpha_pos < beta_pos
      assert beta_pos < zebra_pos
    end

    test "returns empty state message when no stories" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListStoryTitles.execute(%{}, frame)

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "No stories found"
    end
  end

end
