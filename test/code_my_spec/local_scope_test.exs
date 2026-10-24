defmodule CodeMySpec.LocalScopeTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.LocalScope
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope

  test "scope has no environment field" do
    refute Map.has_key?(%Scope{}, :execution_context)
  end

  test "root registration takes precedence over project registration" do
    root = "/tmp/local-scope-root"
    project = project("/tmp/project-path")

    :ok =
      ExecutionContexts.register(
        {:root, root},
        ExecutionContext.new(:local, "/tmp/root-registration")
      )

    :ok =
      ExecutionContexts.register(
        project.id,
        ExecutionContext.new(:local, "/tmp/project-registration")
      )

    on_exit(fn ->
      ExecutionContexts.unregister({:root, root})
      ExecutionContexts.unregister(project.id)
    end)

    assert {:ok, %Scope{cwd: "/tmp/root-registration", active_project: ^project}} =
             LocalScope.for_local_project(project, root)
  end

  test "project registration is used when there is no root registration" do
    project = project(nil)

    :ok =
      ExecutionContexts.register(
        project.id,
        ExecutionContext.new(:local, "/tmp/project-registration")
      )

    on_exit(fn -> ExecutionContexts.unregister(project.id) end)

    assert {:ok, %Scope{cwd: "/tmp/project-registration", user: nil, user_id: nil}} =
             LocalScope.for_local_project(project)
  end

  test "falls back to the explicit root and then the project's local path" do
    project = project("/tmp/project-path")

    assert %ExecutionContext{type: :local, cwd: "/tmp/explicit-root"} =
             LocalScope.execution_context(project, "/tmp/explicit-root")

    assert {:ok, %Scope{cwd: "/tmp/explicit-root"}} =
             LocalScope.for_local_project(project, "/tmp/explicit-root")

    assert %ExecutionContext{type: :local, cwd: "/tmp/project-path"} =
             LocalScope.execution_context(project)

    assert {:ok, %Scope{cwd: "/tmp/project-path"}} = LocalScope.for_local_project(project)
  end

  test "returns no local path when project and root are missing" do
    assert {:error, :no_local_path} = LocalScope.for_local_project(nil)
    assert {:error, :no_local_path} = LocalScope.for_local_project(project(nil))
    assert {:error, :no_local_path} = LocalScope.for_local_project(project(nil), nil)
    assert LocalScope.execution_context(nil) == nil
    assert LocalScope.execution_context(project(nil)) == nil
  end

  defp project(local_path) do
    struct(Project,
      id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      local_path: local_path
    )
  end
end
