defmodule CodeMySpec.McpServers.Stories.Tools.UpdateStoryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory
  alias CodeMySpec.Tags
  alias Hermes.Server.Frame
  alias Hermes.Server.Response
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  defp get_data(response) do
    protocol = Response.to_protocol(response)
    text = hd(protocol["content"])["text"]
    # Extract JSON from "Data: {...}" at the end
    [_, json] = String.split(text, "\n\nData: ")
    Jason.decode!(json)
  end

  describe "UpdateStory tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      params = %{
        id: story.id,
        title: "Updated User Login",
        description: "Updated description"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end

    test "can set tags on a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{
        id: story.id,
        tags: ["accounts", "notifications"]
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      data = get_data(response)
      assert Enum.sort(data["tags"]) == ["accounts", "notifications"]
    end

    test "can replace tags on a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Add initial tags
      Tags.add_tag(scope, story, "old-tag")
      Tags.add_tag(scope, story, "keep-tag")

      # Replace with new set
      params = %{
        id: story.id,
        tags: ["keep-tag", "new-tag"]
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      data = get_data(response)
      assert Enum.sort(data["tags"]) == ["keep-tag", "new-tag"]
    end

    test "can clear all tags from a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Add initial tags
      Tags.add_tag(scope, story, "tag-a")
      Tags.add_tag(scope, story, "tag-b")

      # Clear all tags
      params = %{
        id: story.id,
        tags: []
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      data = get_data(response)
      assert data["tags"] == []
    end
  end
end
