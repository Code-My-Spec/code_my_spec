defmodule CodeMySpec.McpServers.Components.Tools.DeleteComponentTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.DeleteComponent
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "DeleteComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      params = %{id: component.id}

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = DeleteComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      [%{"text" => json_content}] = response.content
      content = Jason.decode!(json_content)
      assert content["id"] == component.id
    end

    test "returns error for non-existent component" do
      scope = full_scope_fixture()
      params = %{id: "00000000-0000-0000-0000-000000000000"}

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = DeleteComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "returns error for invalid scope" do
      component = component_fixture(full_scope_fixture())
      params = %{id: component.id}

      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = DeleteComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end
  end
end
