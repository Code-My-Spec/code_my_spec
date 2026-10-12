defmodule CodeMySpec.AgentTasks.EnvironmentTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects

  test "the selected working copy environment wins over a stale project runtime" do
    scope = working_copy_scope_fixture()
    expected_cwd = fixture_environment(scope).cwd
    stale_root = CodeMySpec.TempFile.owned_dir("stale_scope_environment")
    :ok = Environments.register(scope.active_project_id, Environment.new(:local, stale_root))

    assert %Environment{cwd: cwd} = AgentTasks.environment(scope)
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

    assert AgentTasks.environment(scope) == nil
  end

  test "without a selected working copy, the project local path supplies the environment" do
    scope = full_scope_fixture()
    project_root = CodeMySpec.TempFile.owned_dir("project_environment")

    {:ok, project} =
      Projects.update_project(scope, scope.active_project, %{local_path: project_root})

    :ok = CodeMySpec.Environments.unregister(scope.active_project_id)
    scope = %{scope | active_project: project, active_working_copy_id: nil}

    assert %Environment{cwd: ^project_root} = AgentTasks.environment(scope)
  end
end
