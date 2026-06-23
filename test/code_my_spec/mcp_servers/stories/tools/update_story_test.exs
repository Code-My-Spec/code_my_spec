defmodule CodeMySpec.McpServers.Stories.Tools.UpdateStoryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory
  alias CodeMySpec.Tags
  alias Anubis.Server.Frame
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "UpdateStory tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      params = %{
        story_id: story.id,
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
        story_id: story.id,
        tags: ["accounts", "notifications"]
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
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
        story_id: story.id,
        tags: ["keep-tag", "new-tag"]
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.isError == false
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
        story_id: story.id,
        tags: []
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.isError == false
    end
  end
end
