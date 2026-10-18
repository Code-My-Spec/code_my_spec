defmodule Mix.Tasks.Cms.DeviceOrphansTest do
  @moduledoc false
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias Mix.Tasks.Cms.DeviceOrphans

  defmodule ObservedRepo do
    defdelegate all(query), to: CodeMySpec.Repo
    defdelegate transaction(fun), to: CodeMySpec.Repo

    def delete!(device) do
      Process.get(:before_device_cleanup_delete).(device)
      CodeMySpec.Repo.delete!(device)
    end
  end

  describe "orphan predicate" do
    test "no working copies is an orphan" do
      assert DeviceOrphans.orphan?([])
    end

    test "one working copy is not an orphan" do
      refute DeviceOrphans.orphan?([Ecto.UUID.generate()])
    end

    test "several working copies are not an orphan" do
      refute DeviceOrphans.orphan?([Ecto.UUID.generate(), Ecto.UUID.generate()])
    end
  end

  describe "sandboxed cleanup" do
    setup do
      scope = full_scope_fixture()
      copy = Repo.get!(WorkingCopy, scope.active_working_copy_id)
      attached = Repo.get!(Device, copy.device_id)
      {:ok, orphan} = Devices.announce(scope, nil, %{hostname: attached.hostname, kind: :local})
      other_scope = full_scope_fixture()

      {:ok, other} =
        Devices.announce(other_scope, nil, %{hostname: attached.hostname, kind: :local})

      {:ok, accountless} =
        Devices.announce(%Scope{}, nil, %{hostname: attached.hostname, kind: :local})

      dir = Path.join(File.cwd!(), "_build/test/device_cleanup_#{Ecto.UUID.generate()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      %{
        scope: scope,
        copy: copy,
        attached: attached,
        orphan: orphan,
        other: other,
        accountless: accountless,
        path: Path.join(dir, "backup.json")
      }
    end

    test "dry run reports only scoped orphans without writing or deleting", ctx do
      assert {:ok, %{devices: [device], removed: 0, backup: nil}} =
               DeviceOrphans.cleanup(Repo, ctx.scope, backup: ctx.path)

      assert device.id == ctx.orphan.id
      assert Repo.get!(Device, ctx.orphan.id)
      assert Repo.get!(Device, ctx.other.id)
      assert Repo.get!(WorkingCopy, ctx.copy.id) == ctx.copy
      refute File.exists?(ctx.path)
    end

    test "backup exists before deletion, attached copies survive, and repeat removes nothing",
         ctx do
      Process.put(:before_device_cleanup_delete, fn device ->
        rows = ctx.path |> File.read!() |> Jason.decode!()
        assert Enum.map(rows, & &1["id"]) == [ctx.orphan.id]
        assert Repo.get!(Device, device.id)
        send(self(), {:backed_up_before_delete, device.id})
      end)

      assert {:ok, %{removed: 1, backup: path}} =
               DeviceOrphans.cleanup(ObservedRepo, ctx.scope, commit: true, backup: ctx.path)

      assert path == ctx.path
      assert_received {:backed_up_before_delete, id}
      assert id == ctx.orphan.id
      refute Repo.get(Device, ctx.orphan.id)
      assert Repo.get!(Device, ctx.attached.id) == ctx.attached
      assert Repo.get!(WorkingCopy, ctx.copy.id) == ctx.copy
      assert Repo.get!(Device, ctx.other.id)
      assert Repo.get!(Device, ctx.accountless.id)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      [row] = path |> File.read!() |> Jason.decode!()

      assert Enum.sort(Map.keys(row)) ==
               Enum.sort(Enum.map(Device.__schema__(:fields), &Atom.to_string/1))

      original_backup = File.read!(path)

      assert {:ok, %{devices: [], removed: 0, backup: nil}} =
               DeviceOrphans.cleanup(Repo, ctx.scope, commit: true, backup: path)

      assert File.read!(path) == original_backup
    end

    test "a missing backup directory aborts before deleting any row", ctx do
      assert_raise File.Error, fn ->
        DeviceOrphans.cleanup(Repo, ctx.scope,
          commit: true,
          backup: Path.join(ctx.path, "missing/backup.json")
        )
      end

      assert Repo.get!(Device, ctx.orphan.id)
      assert Repo.get!(WorkingCopy, ctx.copy.id) == ctx.copy
    end

    test "an existing backup cannot be overwritten and no device is deleted", ctx do
      File.write!(ctx.path, "existing backup")

      assert_raise File.Error, fn ->
        DeviceOrphans.cleanup(Repo, ctx.scope, commit: true, backup: ctx.path)
      end

      assert File.read!(ctx.path) == "existing backup"
      assert Repo.get!(Device, ctx.orphan.id)
      assert Repo.get!(WorkingCopy, ctx.copy.id) == ctx.copy
    end
  end

  test "repository configuration preserves its destination" do
    config = [database: "isolated_cleanup_fixture", hostname: "db.example", port: 5433]
    assert DeviceOrphans.configured_repo!(config) == config
  end

  test "missing database configuration is refused" do
    assert_raise ArgumentError, ~r/explicitly configured database/, fn ->
      DeviceOrphans.configured_repo!([])
    end
  end

  test "empty database configuration is refused" do
    assert_raise ArgumentError, ~r/explicitly configured database/, fn ->
      DeviceOrphans.configured_repo!(database: "")
    end
  end
end
