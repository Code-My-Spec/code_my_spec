defmodule CodeMySpec.McpServers.Components.Tools.AddSimilarComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.AddSimilarComponent
  alias Anubis.Server.Frame
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "AddSimilarComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      similar_component = component_fixture(scope, %{name: "Similar Component"})

      params = %{
        component_id: component.id,
        similar_component_id: similar_component.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AddSimilarComponent.execute(params, frame)
      assert response.type == :tool
      assert [%{"type" => "text", "text" => json}] = response.content
      assert json =~ "\"success\":true"
    end

    test "returns error when trying to add self as similar component" do
      scope = full_scope_fixture()
      component = component_fixture(scope)

      params = %{
        component_id: component.id,
        similar_component_id: component.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AddSimilarComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "returns error when component does not exist" do
      scope = full_scope_fixture()
      component = component_fixture(scope)

      params = %{
        component_id: component.id,
        similar_component_id: "00000000-0000-0000-0000-000000000000"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert_raise Ecto.NoResultsError, fn ->
        AddSimilarComponent.execute(params, frame)
      end
    end
  end
end
