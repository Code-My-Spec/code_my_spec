defmodule CodeMySpec.LocalScopeTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.LocalScope
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope

  test "root registration takes precedence over project registration" do
    root = "/tmp/local-scope-root"
    project = project("/tmp/project-path")
    :ok = Environments.register({:root, root}, Environment.new(:local, "/tmp/root-registration"))
    :ok = Environments.register(project.id, Environment.new(:local, "/tmp/project-registration"))

    on_exit(fn ->
      Environments.unregister({:root, root})
      Environments.unregister(project.id)
    end)

    assert {:ok, %Scope{cwd: "/tmp/root-registration", active_project: ^project}} =
             LocalScope.for_local_project(project, root)
  end

  test "project registration is used when there is no root registration" do
    project = project(nil)
    :ok = Environments.register(project.id, Environment.new(:local, "/tmp/project-registration"))
    on_exit(fn -> Environments.unregister(project.id) end)

    assert {:ok, %Scope{cwd: "/tmp/project-registration", user: nil, user_id: nil}} =
             LocalScope.for_local_project(project)
  end

  test "falls back to the explicit root and then the project's local path" do
    project = project("/tmp/project-path")

    assert %Environment{type: :local, cwd: "/tmp/explicit-root"} =
             LocalScope.environment(project, "/tmp/explicit-root")

    assert {:ok, %Scope{cwd: "/tmp/explicit-root"}} =
             LocalScope.for_local_project(project, "/tmp/explicit-root")

    assert %Environment{type: :local, cwd: "/tmp/project-path"} =
             LocalScope.environment(project)

    assert {:ok, %Scope{cwd: "/tmp/project-path"}} = LocalScope.for_local_project(project)
  end

  test "returns no local path when project and root are missing" do
    assert {:error, :no_local_path} = LocalScope.for_local_project(nil)
    assert {:error, :no_local_path} = LocalScope.for_local_project(project(nil))
    assert {:error, :no_local_path} = LocalScope.for_local_project(project(nil), nil)
    assert LocalScope.environment(nil) == nil
    assert LocalScope.environment(project(nil)) == nil
  end

  defp project(local_path) do
    struct(Project,
      id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      local_path: local_path
    )
  end
end
