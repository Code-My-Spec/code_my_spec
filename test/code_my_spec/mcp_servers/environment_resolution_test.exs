defmodule CodeMySpec.McpServers.EnvironmentResolutionTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.WorkingCopies

  test "a selected checkout resolves independently of the scope cwd" do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/mcp-selected-checkout")
    expected = Environment.new(:local, copy.root)
    :ok = Environments.register({:working_copy, copy.id}, expected)
    on_exit(fn -> Environments.unregister({:working_copy, copy.id}) end)
    stale = Environment.new(:local, "/tmp/stale-scope")

    frame = %{assigns: %{current_scope: %{scope | cwd: stale.cwd}}}
    assert Validators.mcp_environment(frame) == expected

    assert Validators.mcp_environment(%{assigns: %{current_scope: %{scope | cwd: nil}}}) ==
             expected
  end

  test "an invalid selected checkout cannot fall back to a bootstrap directory" do
    scope = %{full_scope_fixture() | active_working_copy_id: Ecto.UUID.generate()}
    frame = %{assigns: %{current_scope: scope, working_dir: "/tmp/bootstrap"}}
    assert Validators.mcp_environment(frame) == nil
  end

  test "a checkout from another project is refused" do
    scope = full_scope_fixture()
    other = full_scope_fixture()

    frame = %{
      assigns: %{
        current_scope: %{scope | active_working_copy_id: other.active_working_copy_id},
        working_dir: "/tmp/bootstrap"
      }
    }

    assert Validators.mcp_environment(frame) == nil
  end

  test "bootstrap takes its explicit directory and ignores a stale scope environment" do
    scope = %{full_scope_fixture() | active_working_copy_id: nil}
    frame = %{assigns: %{current_scope: scope, working_dir: "/tmp/bootstrap"}}
    assert %Environment{type: :local, cwd: "/tmp/bootstrap"} = Validators.mcp_environment(frame)
  end
end
