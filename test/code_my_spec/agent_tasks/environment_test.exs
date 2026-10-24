defmodule CodeMySpec.AgentTasks.EnvironmentTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Projects

  test "the selected working copy environment wins over a stale project runtime" do
    scope = working_copy_scope_fixture()
    expected_cwd = fixture_execution_context(scope).cwd
    stale_root = CodeMySpec.TempFile.owned_dir("stale_scope_environment")

    :ok =
      ExecutionContexts.register(
        scope.active_project_id,
        ExecutionContext.new(:local, stale_root)
      )

    assert %ExecutionContext{cwd: cwd} = AgentTasks.execution_context(scope)
    assert cwd == expected_cwd
    refute cwd == stale_root
  end

  test "an invalid selected working copy does not fall back to the project root" do
    scope = full_scope_fixture()
    project_root = CodeMySpec.TempFile.owned_dir("project_environment")

    {:ok, project} =
      Projects.update_project(scope, scope.active_project, %{local_path: project_root})

    scope = %{
      scope
      | active_project: project,
        active_working_copy_id: Ecto.UUID.generate()
    }

    assert AgentTasks.execution_context(scope) == nil
  end

  test "without a selected working copy, the project local path supplies the environment" do
    scope = full_scope_fixture()
    project_root = CodeMySpec.TempFile.owned_dir("project_environment")

    {:ok, project} =
      Projects.update_project(scope, scope.active_project, %{local_path: project_root})

    :ok = CodeMySpec.ExecutionContexts.unregister(scope.active_project_id)
    scope = %{scope | active_project: project, active_working_copy_id: nil}

    assert %ExecutionContext{cwd: ^project_root} = AgentTasks.execution_context(scope)
  end
end
