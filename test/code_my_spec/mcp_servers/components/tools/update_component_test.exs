defmodule CodeMySpec.McpServers.Components.Tools.UpdateComponentTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.UpdateComponent
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "UpdateComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      component = component_fixture(scope)

      params = %{
        id: component.id,
        name: "Updated Component Name",
        description: "Updated description"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = UpdateComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end
end
