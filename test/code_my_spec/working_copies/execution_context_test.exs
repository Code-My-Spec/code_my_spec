defmodule CodeMySpec.WorkingCopies.ExecutionContextTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  test "resolves the selected rooted copy and ignores stale project registration and cwd" do
    scope = full_scope_fixture()
    root = "/tmp/working-copy-environment-selected"
    {:ok, copy} = rooted_copy(scope, root)
    registered = ExecutionContext.new(:local, "/tmp/selected-copy-environment")
    key = {:working_copy, copy.id}
    :ok = ExecutionContexts.register(key, registered)
    on_exit(fn -> ExecutionContexts.unregister(key) end)

    stale = ExecutionContext.new(:local, "/tmp/stale-scope-environment")
    :ok = ExecutionContexts.unregister(scope.active_project_id)
    :ok = ExecutionContexts.register(scope.active_project_id, stale)
    scope = %{scope | active_working_copy_id: copy.id, cwd: "/tmp/stale-cwd"}

    assert WorkingCopies.execution_context(scope) == registered
  end

  test "a root registration is used before synthesis" do
    scope = full_scope_fixture()
    root = "/tmp/working-copy-environment-root-registry"
    {:ok, copy} = rooted_copy(scope, root)
    rooted = ExecutionContext.new(:local, "/tmp/root-registered-environment")
    root_key = {:root, copy.root}
    :ok = ExecutionContexts.register(root_key, rooted)
    on_exit(fn -> ExecutionContexts.unregister(root_key) end)
    scope = %{scope | active_working_copy_id: copy.id}

    assert WorkingCopies.execution_context(scope) == rooted
  end

  test "synthesizes a harness environment for a rooted copy without registrations" do
    scope = full_scope_fixture()

    {:ok, copy} = rooted_copy(scope, "/tmp/working-copy-environment-synthesized")

    assert %ExecutionContext{type: :harness, cwd: cwd, ref: %{"harness_id" => id}} =
             WorkingCopies.execution_context(%{scope | active_working_copy_id: copy.id})

    assert cwd == copy.root
    assert id == copy.id
  end

  test "refuses an active copy that belongs to another project, even if it is registered" do
    selected_scope = full_scope_fixture()
    other_scope = full_scope_fixture()

    {:ok, other_copy} =
      rooted_copy(other_scope, "/tmp/working-copy-environment-other-project")

    key = {:working_copy, other_copy.id}
    :ok = ExecutionContexts.register(key, ExecutionContext.new(:local, "/tmp/wrong-project"))
    on_exit(fn -> ExecutionContexts.unregister(key) end)

    selected_scope = %{selected_scope | active_working_copy_id: other_copy.id}

    assert WorkingCopies.execution_context(selected_scope) == nil
  end

  test "returns nil for missing ids, missing rows, and copies without a root" do
    %Scope{} = scope = full_scope_fixture()
    {:ok, unrooted} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))

    assert WorkingCopies.execution_context(%Scope{scope | active_working_copy_id: nil}) == nil

    assert WorkingCopies.execution_context(%Scope{scope | active_working_copy_id: "not-a-uuid"}) ==
             nil

    assert WorkingCopies.execution_context(%Scope{
             scope
             | active_working_copy_id: Ecto.UUID.generate()
           }) == nil

    assert WorkingCopies.execution_context(%Scope{scope | active_working_copy_id: unrooted.id}) ==
             nil

    assert WorkingCopies.execution_context(%Scope{scope | active_project_id: nil}) == nil
  end

  test "different rooted copies in one project resolve independently" do
    scope = full_scope_fixture()

    {:ok, first} =
      rooted_copy(scope, "/tmp/working-copy-environment-first")

    {:ok, second} =
      rooted_copy(scope, "/tmp/working-copy-environment-second")

    first_env = ExecutionContext.new(:local, "/tmp/first-copy")
    second_env = ExecutionContext.new(:local, "/tmp/second-copy")
    first_key = {:working_copy, first.id}
    second_key = {:working_copy, second.id}
    :ok = ExecutionContexts.register(first_key, first_env)
    :ok = ExecutionContexts.register(second_key, second_env)

    on_exit(fn ->
      ExecutionContexts.unregister(first_key)
      ExecutionContexts.unregister(second_key)
    end)

    assert WorkingCopies.execution_context(%{scope | active_working_copy_id: first.id}) ==
             first_env

    assert WorkingCopies.execution_context(%{scope | active_working_copy_id: second.id}) ==
             second_env
  end

  defp rooted_copy(scope, root) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    WorkingCopies.report_root(copy, root)
  end
end
