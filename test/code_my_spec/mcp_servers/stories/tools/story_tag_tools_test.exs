defmodule CodeMySpec.McpServers.Stories.Tools.StoryTagToolsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Stories.Tools.AddStoryTag
  alias CodeMySpec.McpServers.Stories.Tools.RemoveStoryTag
  alias CodeMySpec.McpServers.Stories.Tools.ListStoryTags
  alias CodeMySpec.McpServers.Stories.Tools.ListStoriesByTag
  alias CodeMySpec.McpServers.Stories.Tools.ListProjectTags
  alias CodeMySpec.McpServers.Stories.Tools.TagStories
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  defp get_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  describe "AddStoryTag tool" do
    test "adds a tag to a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{story_id: to_string(story.id), tag: "accounts"}

      assert {:reply, response, ^frame} = AddStoryTag.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "accounts"
      assert text =~ story.title
    end

    test "returns error for non-existent story" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{story_id: "99999", tag: "accounts"}

      assert {:reply, response, ^frame} = AddStoryTag.execute(params, frame)
      assert response.isError == true
    end
  end

  describe "RemoveStoryTag tool" do
    test "removes a tag from a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # First add a tag
      add_params = %{story_id: to_string(story.id), tag: "remove-me"}
      {:reply, _, _} = AddStoryTag.execute(add_params, frame)

      # Then remove it
      remove_params = %{story_id: to_string(story.id), tag: "remove-me"}
      assert {:reply, response, ^frame} = RemoveStoryTag.execute(remove_params, frame)
      assert response.type == :tool
      assert response.isError == false
    end

    test "returns error for non-existent tag" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{story_id: to_string(story.id), tag: "nonexistent"}

      assert {:reply, response, ^frame} = RemoveStoryTag.execute(params, frame)
      assert response.isError == true
    end
  end

  describe "ListStoryTags tool" do
    test "lists tags for a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Add some tags
      AddStoryTag.execute(%{story_id: to_string(story.id), tag: "tag-a"}, frame)
      AddStoryTag.execute(%{story_id: to_string(story.id), tag: "tag-b"}, frame)

      params = %{story_id: to_string(story.id)}
      assert {:reply, response, ^frame} = ListStoryTags.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "tag-a"
      assert text =~ "tag-b"
    end

    test "returns empty list for untagged story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{story_id: to_string(story.id)}
      assert {:reply, response, ^frame} = ListStoryTags.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "no tags"
    end
  end

  describe "ListStoriesByTag tool" do
    test "lists stories with a specific tag" do
      scope = full_scope_fixture()
      story1 = story_fixture(scope, %{title: "Story 1"})
      story2 = story_fixture(scope, %{title: "Story 2"})
      _story3 = story_fixture(scope, %{title: "Story 3"})
      frame = %Frame{assigns: %{current_scope: scope}}

      # Tag only first two stories
      AddStoryTag.execute(%{story_id: to_string(story1.id), tag: "shared-tag"}, frame)
      AddStoryTag.execute(%{story_id: to_string(story2.id), tag: "shared-tag"}, frame)

      params = %{tag: "shared-tag"}
      assert {:reply, response, ^frame} = ListStoriesByTag.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "Story 1"
      assert text =~ "Story 2"
      refute text =~ "Story 3"
    end

    test "returns empty list for unknown tag" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{tag: "unknown-tag"}
      assert {:reply, response, ^frame} = ListStoriesByTag.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "No stories found"
    end
  end

  describe "ListProjectTags tool" do
    test "lists all tags in the project" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Create some tags
      AddStoryTag.execute(%{story_id: to_string(story.id), tag: "alpha"}, frame)
      AddStoryTag.execute(%{story_id: to_string(story.id), tag: "beta"}, frame)

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
