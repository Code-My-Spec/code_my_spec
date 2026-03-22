defmodule CodeMySpec.McpServers.Components.Tools.ListComponentsTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Components.Tools.ListComponents
  alias Anubis.Server.Frame

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "ListComponents tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      params = %{project_id: "project-123"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ListComponents.execute(params, frame)
      assert response.type == :tool
    end
  end
end
