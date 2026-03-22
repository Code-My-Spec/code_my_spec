defmodule CodeMySpec.McpServers.Components.Tools.DeleteDependencyTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.DeleteDependency
  alias Anubis.Server.Frame
  alias CodeMySpec.Components
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "DeleteDependency tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      source_component = component_fixture(scope, %{name: "SourceComponent", type: "context"})
      target_component = component_fixture(scope, %{name: "TargetComponent", type: "schema"})

      # Create a dependency to delete
      {:ok, dependency} =
        Components.create_dependency(scope, %{
          source_component_id: source_component.id,
          target_component_id: target_component.id
        })

      params = %{id: dependency.id}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = DeleteDependency.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      # Extract JSON data from response content
      [%{"text" => json_text}] = response.content
      response_data = Jason.decode!(json_text)

      assert response_data["id"] == dependency.id
      assert response_data["deleted"] == true
      assert response_data["source_component"]["id"] == source_component.id
      assert response_data["target_component"]["id"] == target_component.id
    end

    test "handles non-existent dependency" do
      scope = full_scope_fixture()
      params = %{id: 99999}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert_raise Ecto.NoResultsError, fn ->
        DeleteDependency.execute(params, frame)
      end
    end
  end
end
