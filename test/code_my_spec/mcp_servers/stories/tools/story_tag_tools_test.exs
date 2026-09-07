defmodule CodeMySpec.McpServers.Stories.Tools.StoryTagToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Stories.Tools.ListProjectTags
  alias CodeMySpec.McpServers.Stories.Tools.TagStories
  alias CodeMySpec.Tags
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  defp get_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  describe "ListProjectTags tool" do
    test "lists all tags in the project" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Create some tags using Tags context directly
      Tags.add_tag(scope, story, "alpha")
      Tags.add_tag(scope, story, "beta")

      assert {:reply, response, ^frame} = ListProjectTags.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "alpha"
      assert text =~ "beta"
    end

    test "returns empty message when no tags exist" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListProjectTags.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "No tags found"
    end
  end

  describe "TagStories tool" do
    test "tags multiple stories at once" do
      scope = full_scope_fixture()
      story1 = story_fixture(scope, %{title: "Bulk 1"})
      story2 = story_fixture(scope, %{title: "Bulk 2"})
      story3 = story_fixture(scope, %{title: "Bulk 3"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{
        story_ids: [to_string(story1.id), to_string(story2.id), to_string(story3.id)],
        tag: "bulk-tag"
      }

      assert {:reply, response, ^frame} = TagStories.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "Tagged 3 stories"
    end

    test "reports failures for non-existent stories" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{
        story_ids: [to_string(story.id), "99999", "88888"],
        tag: "partial-tag"
      }

      assert {:reply, response, ^frame} = TagStories.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "Tagged 1 stories"
      assert text =~ "Not found"
    end
  end
end
