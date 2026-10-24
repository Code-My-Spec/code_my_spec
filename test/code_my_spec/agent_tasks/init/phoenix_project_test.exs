defmodule CodeMySpec.AgentTasks.Init.PhoenixProjectTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.Init.PhoenixProject
  alias CodeMySpec.ExecutionContexts

  test "reports no environment when the selected working copy has no runtime" do
    scope = %{working_copy_scope_fixture() | active_working_copy_id: Ecto.UUID.generate()}

    assert {:error, :no_environment} = PhoenixProject.evaluate(scope, %{})
  end

  test "checks project files in the registered working copy environment" do
    scope = working_copy_scope_fixture()
    root = CodeMySpec.TempFile.owned_dir("phoenix_project_environment")
    env = CodeMySpec.ExecutionContexts.ExecutionContext.new(:local, root)
    :ok = register_working_copy_execution_context(scope, env)

    assert {:ok, :invalid, message} = PhoenixProject.evaluate(scope, %{})
    assert message =~ "missing: mix.exs, lib/, config/"

    for path <- ["mix.exs", "lib/.gitkeep", "config/.gitkeep"] do
      :ok = ExecutionContexts.write_file(env, path, "")
    end

    assert {:ok, :valid} = PhoenixProject.evaluate(scope, %{})
  end
end
