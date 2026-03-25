defmodule CodeMySpec.McpServers.Stories.Tools.SetStoryComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias Anubis.Server.Frame
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "SetStoryComponent tool" do
    test "executes with valid module_name" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      component = component_fixture(scope)

      params = %{
        story_id: Integer.to_string(story.id),
        module_name: component.module_name
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
        module_name: component.module_name
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = SetStoryComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "returns error when component not found by module_name" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      params = %{
        story_id: Integer.to_string(story.id),
        module_name: "NonExistent.Module"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = SetStoryComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end
  end
end
