defmodule CodeMySpec.McpServers.Components.Tools.CreateDependencyTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.CreateDependency
  alias Anubis.Server.Frame
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "CreateDependency tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      source_component = component_fixture(scope, %{name: "SourceComponent", type: "context"})
      target_component = component_fixture(scope, %{name: "TargetComponent", type: "schema"})

      params = %{
        source_component_id: source_component.id,
        target_component_id: target_component.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = CreateDependency.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      # Extract JSON data from response content
      [%{"text" => json_text}] = response.content
      response_data = Jason.decode!(json_text)

      assert response_data["id"]
      assert response_data["source_component"]["id"] == source_component.id
      assert response_data["target_component"]["id"] == target_component.id
    end

    test "prevents self-dependencies" do
      scope = full_scope_fixture()
      component = component_fixture(scope, %{name: "SelfComponent", type: "context"})

      params = %{
        source_component_id: component.id,
        target_component_id: component.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = CreateDependency.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "detects circular dependencies" do
      scope = full_scope_fixture()
      component_a = component_fixture(scope, %{name: "ComponentA", type: "context"})
      component_b = component_fixture(scope, %{name: "ComponentB", type: "context"})

      # Create first dependency A -> B
      first_params = %{
        source_component_id: component_a.id,
        target_component_id: component_b.id
      }

      frame = %Frame{assigns: %{current_scope: scope}}
      assert {:reply, _response, ^frame} = CreateDependency.execute(first_params, frame)

      # Try to create circular dependency B -> A
      circular_params = %{
        source_component_id: component_b.id,
        target_component_id: component_a.id
      }

      assert {:reply, response, ^frame} = CreateDependency.execute(circular_params, frame)
      assert response.type == :tool
      assert response.isError == true

      # Extract error message from response content
      [%{"text" => error_text}] = response.content
      assert String.contains?(error_text, "Circular dependency detected")
    end
  end
end
