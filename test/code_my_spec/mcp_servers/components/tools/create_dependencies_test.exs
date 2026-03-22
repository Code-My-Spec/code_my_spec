defmodule CodeMySpec.McpServers.Components.Tools.CreateDependenciesTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Components.Tools.CreateDependencies
  alias Anubis.Server.Frame
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "CreateDependencies tool" do
    test "executes with valid params and scope" do
      params = %{
        dependencies: [
          %{
            "type" => "require",
            "source_component_id" => 1,
            "target_component_id" => 2
          },
          %{
            "type" => "import",
            "source_component_id" => 2,
            "target_component_id" => 3
          }
        ]
      }

      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}
      assert {:reply, response, ^frame} = CreateDependencies.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end
end
