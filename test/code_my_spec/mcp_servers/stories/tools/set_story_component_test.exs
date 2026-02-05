defmodule CodeMySpec.McpServers.Stories.Tools.SetStoryComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias Hermes.Server.Frame
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "SetStoryComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      component = component_fixture(scope)

      params = %{
        story_id: Integer.to_string(story.id),
        component_id: component.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = SetStoryComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end

    test "returns error when story not found" do
      scope = full_scope_fixture()
      component = component_fixture(scope)

      params = %{
        story_id: "999999",
        component_id: component.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = SetStoryComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "allows setting component_id that doesn't exist in database" do
      # Component IDs can reference components that only exist in CLI environments
      # (local spec files), not necessarily in the server database
      scope = full_scope_fixture()
      story = story_fixture(scope)

      params = %{
        story_id: Integer.to_string(story.id),
        component_id: "00000000-0000-0000-0000-000000000000"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = SetStoryComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end
end
