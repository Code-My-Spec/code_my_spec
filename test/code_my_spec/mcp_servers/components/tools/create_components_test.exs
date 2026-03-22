defmodule CodeMySpec.McpServers.Components.Tools.CreateComponentsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.CreateComponents
  alias Anubis.Server.Frame
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "CreateComponents tool" do
    test "executes with valid params and scope" do
      params = %{
        components: [
          %{
            "name" => "UserService",
            "type" => "service",
            "module_name" => "MyApp.UserService",
            "description" => "Handles user management operations"
          },
          %{
            "name" => "AuthController",
            "type" => "controller",
            "module_name" => "MyApp.AuthController",
            "description" => "Handles authentication endpoints"
          }
        ]
      }

      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}
      assert {:reply, response, ^frame} = CreateComponents.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end
end
