defmodule CodeMySpec.McpServers.Stories.Tools.ClearStoryComponentTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Stories.Tools.ClearStoryComponent
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "clears component from a linked story" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      story = story_fixture(scope, %{component_id: component.id})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert story.component_id == component.id

      assert {:reply, response, ^frame} =
               ClearStoryComponent.execute(%{story_id: to_string(story.id)}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "cleared" or content =~ "unlinked" or content =~ story.title
    end

    test "handles already-unlinked story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert is_nil(story.component_id)

      assert {:reply, response, ^frame} =
               ClearStoryComponent.execute(%{story_id: to_string(story.id)}, frame)

      refute response.isError
    end

    test "returns error for non-existent story" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ClearStoryComponent.execute(%{story_id: "999999"}, frame)

      assert response.isError
      assert response_text(response) =~ "not found"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} =
               ClearStoryComponent.execute(%{story_id: 1}, frame)

      assert response.isError
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
