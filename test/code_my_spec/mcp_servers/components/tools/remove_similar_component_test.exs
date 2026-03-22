defmodule CodeMySpec.McpServers.Components.Tools.RemoveSimilarComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.RemoveSimilarComponent
  alias CodeMySpec.Components
  alias Anubis.Server.Frame
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "RemoveSimilarComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      similar_component = component_fixture(scope, %{name: "Similar Component"})

      # First add the similar component
      {:ok, _} = Components.add_similar_component(scope, component, similar_component)

      params = %{
        component_id: component.id,
        similar_component_id: similar_component.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = RemoveSimilarComponent.execute(params, frame)
      assert response.type == :tool
      assert [%{"type" => "text", "text" => json}] = response.content
      assert json =~ "\"deleted\":true"
    end

    test "returns error when relationship does not exist" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      similar_component = component_fixture(scope, %{name: "Similar Component"})

      params = %{
        component_id: component.id,
        similar_component_id: similar_component.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = RemoveSimilarComponent.execute(params, frame)
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
        RemoveSimilarComponent.execute(params, frame)
      end
    end
  end
end
