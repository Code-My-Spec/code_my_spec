defmodule CodeMySpec.McpServers.Components.Tools.CreateComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias Anubis.Server.Frame
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "CreateComponent tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()

      params = %{
        name: "LoginButton",
        type: "context",
        module_name: "MyApp.LoginButton",
        description: "A button component for user login"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = CreateComponent.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end
end
