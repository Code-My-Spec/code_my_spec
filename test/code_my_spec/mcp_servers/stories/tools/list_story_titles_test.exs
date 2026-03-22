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

      # Verify lightweight data structure (no criteria)
      data = extract_json_data(content)
      story = hd(data["stories"])
      assert Map.has_key?(story, "id")
      assert Map.has_key?(story, "title")
      assert Map.has_key?(story, "component_id")
      refute Map.has_key?(story, "criteria")
      refute Map.has_key?(story, "description")
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
      data = extract_json_data(hd(protocol["content"])["text"])

      titles = Enum.map(data["stories"], & &1["title"])
      assert titles == ["Alpha Story", "Beta Story", "Zebra Story"]
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

  defp extract_json_data(text) do
    [_, json] = String.split(text, "Data: ", parts: 2)
    Jason.decode!(json)
  end
end
