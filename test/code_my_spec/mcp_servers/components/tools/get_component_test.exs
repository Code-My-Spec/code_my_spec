defmodule CodeMySpec.McpServers.Components.Tools.GetComponentTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.GetComponent
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
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

    # With spec files gone, this is how an agent reads one component.
    test "by module name: parent, dependencies and files" do
      scope = full_scope_fixture()
      parent = component_fixture(scope, %{name: "Accounts", module_name: "MyApp.Accounts"})
      repo = component_fixture(scope, %{name: "Repo", module_name: "MyApp.Repo"})

      user =
        component_fixture(scope, %{
          name: "User",
          module_name: "MyApp.Accounts.User",
          parent_component_id: parent.id
        })

      {:ok, _} =
        CodeMySpec.Components.create_dependency(scope, %{
          source_component_id: user.id,
          target_component_id: repo.id
        })

      CodeMySpec.Repo.insert!(%CodeMySpec.Files.File{
        project_id: scope.active_project_id,
        working_copy_id: scope.active_working_copy_id,
        path: "lib/my_app/accounts/user.ex",
        role: :implementation,
        component_id: user.id
      })

      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _} = GetComponent.execute(%{module_name: "MyApp.Accounts.User"}, frame)
      [%{"text" => json}] = response.content
      got = Jason.decode!(json)

      assert got["id"] == user.id
      assert got["parent"] == "MyApp.Accounts"
      assert got["dependencies"] == ["MyApp.Repo"]
      assert got["files"] == ["lib/my_app/accounts/user.ex"]
    end

    test "neither id nor module name is refused" do
      frame = %Frame{assigns: %{current_scope: full_scope_fixture()}}
      {:reply, response, _} = GetComponent.execute(%{}, frame)
      assert response.isError
    end
  end
end
