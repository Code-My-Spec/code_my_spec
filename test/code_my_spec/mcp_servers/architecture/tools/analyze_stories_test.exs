defmodule CodeMySpec.McpServers.Architecture.Tools.AnalyzeStoriesTest do
  use ExUnit.Case, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.TagsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "analyzes stories grouped by tags" do
      scope = full_scope_fixture()
      story1 = story_fixture(scope, %{title: "User login"})
      story2 = story_fixture(scope, %{title: "User signup"})
      _story3 = story_fixture(scope, %{title: "Dashboard"})

      story_tagging_fixture(scope, story1, "auth")
      story_tagging_fixture(scope, story2, "auth")
      story_tagging_fixture(scope, story1, "security")

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStories.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "Story Analysis"
      assert content =~ "auth"
      assert content =~ "security"
      assert content =~ "Untagged"
      assert content =~ "Dashboard"
    end

    test "reports co-occurrences for tags appearing together 2+ times" do
      scope = full_scope_fixture()
      story1 = story_fixture(scope, %{title: "Feature A"})
      story2 = story_fixture(scope, %{title: "Feature B"})

      # Both stories have both tags → co-occurrence count = 2
      story_tagging_fixture(scope, story1, "frontend")
      story_tagging_fixture(scope, story1, "api")
      story_tagging_fixture(scope, story2, "frontend")
      story_tagging_fixture(scope, story2, "api")

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStories.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "Co-occurrence"
      assert content =~ "frontend"
      assert content =~ "api"
    end

    test "returns error when no stories exist" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStories.execute(%{}, frame)

      assert response.isError
      content = response_text(response)
      assert content =~ "No stories found"
    end

    test "handles stories with no tags" do
      scope = full_scope_fixture()
      _story = story_fixture(scope, %{title: "Untagged story"})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStories.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "Untagged:** 1"
      assert content =~ "No tags found"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = AnalyzeStories.execute(%{}, frame)

      assert response.isError
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
