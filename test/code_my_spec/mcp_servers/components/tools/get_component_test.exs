defmodule CodeMySpec.McpServers.Components.Tools.GetComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.GetComponent
  alias Anubis.Server.Frame
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "GetComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      params = %{component_id: component.id}

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetComponent.execute(params, frame)
      assert response.type == :tool
    end
  end
end
