defmodule CodeMySpec.Files.LockfileReconcileTest do
  @moduledoc """
  577de9bb step 3's trigger: `project_dependencies` is populated from the
  MAIN copy's `mix.lock`, and only from there. A changed lock on any other
  copy is not this project's dependency set — two checkouts can disagree
  mid-deploy, and only one of them is what the server tells anyone about.

  `FileSync.reconcile_lockfile/1` is exercised through `FileSync.sync/2`
  against a real tmp dir (same fixture shape `FileSync.sync/2`'s own tests
  use) rather than against a mocked channel — fast, and realistic about
  what a manifest sync actually triggers. `LockfileSweep` is exercised
  separately, since its scopes are `:harness`-typed and the thing worth
  proving about it is that an unreachable harness is a quiet no-op, not a
  crash — matching `Environments.Harness`'s own documented contract.
  """

  use ExUnit.Case, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.LockfileSweep
  alias CodeMySpec.Projects
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  @lock """
  %{
    "bandit": {:hex, :bandit, "1.10.4", "chk", [:mix], [], "hexpm", "chk2"},
  }
  """

  @other_lock """
  %{
    "bandit": {:hex, :bandit, "1.10.5", "chk", [:mix], [], "hexpm", "chk2"},
  }
  """

  describe "classify/1" do
    test "classifies mix.lock as lockfile" do
      assert {"mix.lock", :lockfile} = FileSync.classify("mix.lock")
    end
  end

  describe "a full sync's lockfile reconcile" do
    test "the main copy's mix.lock is read and recorded" do
      {scope, tmp_dir} = project_with_copy(@lock, main?: true)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      assert [%{name: "bandit", version: "1.10.4"}] = dependency_names_and_versions(scope)
      assert is_binary(stamped_fingerprint(scope))
    end

    test "a non-main copy's mix.lock is never recorded" do
      {scope, tmp_dir} = project_with_copy(@lock, main?: false)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      assert dependency_names_and_versions(scope) == []
      assert is_nil(stamped_fingerprint(scope))
    end

    test "a project with no mix.lock yet is untouched" do
      {scope, tmp_dir} = project_with_copy(nil, main?: true)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      assert dependency_names_and_versions(scope) == []
      assert is_nil(stamped_fingerprint(scope))
    end

    test "a second sync of the same lock does not read it again" do
      {scope, tmp_dir} = project_with_copy(@lock, main?: true)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      fingerprint_after_first = stamped_fingerprint(scope)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      fingerprint_after_second = stamped_fingerprint(scope)

      assert fingerprint_after_first == fingerprint_after_second
      assert [%{name: "bandit", version: "1.10.4"}] = dependency_names_and_versions(scope)
    end

    test "a lock that actually changes is re-read and re-recorded" do
      {scope, tmp_dir} = project_with_copy(@lock, main?: true)
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      fingerprint_after_first = stamped_fingerprint(scope)

      write_mix_lock(tmp_dir, @other_lock)
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      assert [%{name: "bandit", version: "1.10.5"}] = dependency_names_and_versions(scope)
      assert stamped_fingerprint(scope) != fingerprint_after_first
    end
  end

  describe "WorkingCopies.main_copy_scopes/0" do
    test "returns one scope per project with a designated main copy" do
      {scope, _tmp_dir} = project_with_copy(@lock, main?: true)

      scopes = WorkingCopies.main_copy_scopes()
      found = Enum.find(scopes, &(&1.active_project_id == scope.active_project_id))

      assert found.active_account_id == scope.active_account_id
      assert %Environment{type: :harness} = found.environment
    end
  end

  describe "LockfileSweep.sweep_now/0" do
    # The scopes `main_copy_scopes/0` builds are `:harness`-typed, reached
    # over a channel this test opens none of — exactly the "harness offline"
    # case `Environments.Harness`'s own moduledoc documents as a quiet
    # `{:error, _}`, not a raise. The sweep's whole value is surviving that
    # for every *other* project while this one waits for its harness to
    # come back, so proving it does not crash is the property that matters
    # here — the successful read is already covered via `FileSync.sync/2`
    # above.
    test "an unreachable main copy is skipped, not crashed on" do
      {scope, _tmp_dir} = project_with_copy(@lock, main?: true)

      assert :ok = LockfileSweep.sweep_now()
      assert dependency_names_and_versions(scope) == []
    end
  end

  defp project_with_copy(lock_content, opts) do
    tmp_dir = CodeMySpec.TempFile.owned_dir("test")
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "test copy", device: device_fixture(scope))

    main_copy_id = designated_copy_id(scope, copy, opts[:main?])

    write_mix_lock(tmp_dir, lock_content)

    {%{
       scope
       | active_project: project,
         active_working_copy_id: main_copy_id,
         cwd: tmp_dir,
         environment: Environment.new(:local, tmp_dir)
     }, tmp_dir}
  end

  defp designated_copy_id(_scope, copy, false), do: copy.id

  defp designated_copy_id(scope, copy, true) do
    {:ok, main_copy} = WorkingCopies.designate_main(scope, copy.id)
    main_copy.id
  end

  defp write_mix_lock(_tmp_dir, nil), do: :ok

  defp write_mix_lock(tmp_dir, content) do
    File.write!(Path.join(tmp_dir, "mix.lock"), content)
  end

  defp dependency_names_and_versions(scope) do
    scope
    |> Dependencies.list_dependencies()
    |> Enum.map(&Map.take(&1, [:name, :version]))
  end

  defp stamped_fingerprint(scope) do
    scope.active_project_id
    |> then(&Projects.get_project!(scope, &1))
    |> Map.fetch!(:mix_lock_fingerprint)
  end
end
