defmodule CmsHarness.AppInstanceIdentityTest do
  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarness.AppInstance
  alias CmsHarnessTest.FakeAppInstanceRunner

  setup do
    directory = CodeMySpec.TempFile.dir("app-instance-identities")
    previous = Application.get_env(:code_my_spec, :app_instances_root)
    Application.put_env(:code_my_spec, :app_instances_root, directory)

    on_exit(fn ->
      restore_storage(previous)

      File.rm_rf!(directory)
    end)

    %{storage: directory}
  end

  test "two instances sharing a source have separate identity, ports and database" do
    %{root: root} = app_instance_rig()
    first = instance(root)

    second =
      Map.merge(first, %{
        "instance_id" => Ecto.UUID.generate(),
        "default" => false,
        "database_source" => "fakeapp_dev"
      })

    on_exit(fn -> terminate(second) end)

    assert {:ok, %{instance_id: first_id}} = AppInstance.ensure_running(first)
    first_state = :sys.get_state(AppInstance.via(first))
    FakeAppInstanceRunner.configure(launch_result: {:ok, 99_999})
    assert {:ok, %{instance_id: second_id}} = AppInstance.ensure_running(second)
    second_state = :sys.get_state(AppInstance.via(second))

    refute first_id == second_id
    refute first_state.port == second_state.port
    refute first_state.database == second_state.database
    refute first_state.log_path == second_state.log_path
    assert first_state.root == second_state.root
    hint = Path.join(root, ".code_my_spec/status/database_name")
    assert File.read!(hint) == first_state.database
    assert :ok = AppInstance.stop_app(first)
    assert Process.alive?(GenServer.whereis(AppInstance.via(second)))
    assert AppInstance.reported(second)["instance_id"] == second_id
  end

  test "persistence does not force configured ports or database" do
    %{root: root} = app_instance_rig()
    descriptor = Map.put(instance(root), "persistent", true)
    assert {:ok, _} = AppInstance.ensure_running(descriptor)
    pid = GenServer.whereis(AppInstance.via(descriptor))
    send(pid, :timeout)
    state = :sys.get_state(pid)
    assert state.persistent
    refute state.port == 4000
    assert String.contains?(state.database, "_dev_wc_")
    refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:stop_process, _}, &1))
  end

  test "configured ports and cloned database are independent policies" do
    %{root: root} = app_instance_rig()
    descriptor = Map.put(instance(root), "port_mode", "configured")
    assert {:ok, _} = AppInstance.ensure_running(descriptor)
    state = :sys.get_state(AppInstance.via(descriptor))
    assert state.port == 4000
    assert String.contains?(state.database, "_dev_wc_")
    refute state.persistent
    refute state.after_promote
  end

  test "a failed stop preserves the runtime and prevents destructive discard" do
    %{root: root} = app_instance_rig(stop_result: {:error, :stop_not_confirmed})
    descriptor = instance(root)
    assert {:ok, _} = AppInstance.ensure_running(descriptor)
    assert {:error, :stop_not_confirmed} = AppInstance.stop_app(descriptor)
    assert {:error, :stop_not_confirmed} = AppInstance.discard(descriptor)
    assert AppInstance.reported(descriptor)["status"] == "serving"
    refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:drop_database, _}, &1))
  end

  test "discard wire confirms cleanup and reports its instance identity" do
    %{root: root} = app_instance_rig()
    descriptor = instance(root)
    assert %{"status" => "ok"} = push_app_event("ensure_app_running")
    assert %{"status" => "ok", "instance_id" => id} = push_app_event("discard_app")
    assert id == descriptor["instance_id"]
    assert AppInstance.reported(descriptor) == nil
    assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:drop_database, _}, &1))
    assert File.dir?(root)
  end

  test "a failed database drop preserves the resource identity for retry" do
    %{root: root} = app_instance_rig(drop_result: {:error, :database_busy})
    descriptor = instance(root)
    assert {:ok, _} = AppInstance.ensure_running(descriptor)
    original = :sys.get_state(AppInstance.via(descriptor))
    assert {:error, :database_busy} = AppInstance.discard(descriptor)
    assert AppInstance.reported(descriptor)["status"] == "down"
    assert :sys.get_state(AppInstance.via(descriptor)).database == original.database
    FakeAppInstanceRunner.configure(drop_result: :ok)
    assert :ok = AppInstance.discard(descriptor)
    assert AppInstance.reported(descriptor) == nil
  end

  test "configured storage cannot be reclassified as a disposable clone" do
    %{root: root} = app_instance_rig()
    descriptor = Map.put(instance(root), "database_mode", "configured")
    assert {:ok, _} = AppInstance.ensure_running(descriptor)
    original = :sys.get_state(AppInstance.via(descriptor))
    changed = Map.put(descriptor, "database_mode", "clone")
    assert {:error, :instance_storage_policy_mismatch} = AppInstance.discard(changed)
    assert :sys.get_state(AppInstance.via(descriptor)).database == original.database
    terminate(descriptor)
    assert {:error, :instance_storage_policy_mismatch} = AppInstance.discard(changed)
    refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:drop_database, _}, &1))
  end

  test "a live process with unknown ownership cannot be acknowledged as stopped" do
    %{root: root} = app_instance_rig()
    descriptor = instance(root)
    assert {:ok, _} = AppInstance.ensure_running(descriptor)
    pid = :sys.get_state(AppInstance.via(descriptor)).os_pid
    FakeAppInstanceRunner.put_process_root(nil)

    assert {:error, {:cannot_confirm_process_stopped, ^pid}} = AppInstance.stop_app(descriptor)
    assert {:error, {:cannot_confirm_process_stopped, ^pid}} = AppInstance.discard(descriptor)
    assert AppInstance.reported(descriptor)["status"] == "serving"
    refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:stop_process, _}, &1))
    refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:drop_database, _}, &1))
  end

  test "runtime survives source copy supervision and restores its durable identity" do
    %{root: root} = app_instance_rig()
    descriptor = instance(root)
    assert {:ok, _} = AppInstance.ensure_running(descriptor)
    original = :sys.get_state(AppInstance.via(descriptor))
    pid = GenServer.whereis(AppInstance.via(descriptor))

    assert :ok = CmsHarness.Copy.Supervisor.stop(root)
    assert Process.alive?(pid)
    terminate(descriptor)
    assert {:ok, info} = AppInstance.ensure_running(descriptor)
    restored = :sys.get_state(AppInstance.via(descriptor))

    assert info.instance_id == descriptor["instance_id"]
    assert restored.os_pid == original.os_pid
    assert restored.port == original.port
    assert restored.database == original.database
    assert restored.commit == original.commit
  end

  test "legacy runtime is claimed once and preserves its process, ports, database and log", %{
    storage: storage
  } do
    %{root: root} = app_instance_rig()
    descriptor = instance(root)
    hash = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    legacy = Path.join(storage, hash)
    File.mkdir_p!(legacy)
    File.write!(Path.join(legacy, "app.log"), "existing log\n")

    File.write!(
      Path.join(legacy, "state.json"),
      Jason.encode!(%{
        "port" => 43_211,
        "https_port" => 43_212,
        "database" => "fakeapp_dev_wc_legacy",
        "os_pid" => 12_345,
        "commit" => "legacy-head",
        "serving_commit" => "legacy-served",
        "status" => "serving"
      })
    )

    FakeAppInstanceRunner.put_process_root(root)

    assert {:ok, %{commit: "legacy-head", serving_commit: "legacy-served"}} =
             AppInstance.ensure_running(descriptor)

    restored = :sys.get_state(AppInstance.via(descriptor))
    assert restored.os_pid == 12_345
    assert restored.port == 43_211
    assert restored.database == "fakeapp_dev_wc_legacy"
    assert restored.log_path == Path.join(legacy, "app.log")
    assert File.read!(Path.join(legacy, "instance-owner")) == descriptor["instance_id"]

    other =
      Map.merge(descriptor, %{
        "instance_id" => Ecto.UUID.generate(),
        "default" => false,
        "database_source" => "fakeapp_dev"
      })

    on_exit(fn -> terminate(other) end)
    assert {:ok, _} = AppInstance.ensure_running(other)
    refute :sys.get_state(AppInstance.via(other)).port == restored.port
  end

  test "channel refuses a descriptor naming another checkout" do
    %{root: root} = app_instance_rig()
    descriptor = Map.put(instance(root), "root", Path.join(root, "somewhere-else"))

    assert %{"status" => "error"} =
             push_app_event_with("ensure_app_running", %{"instance" => descriptor})

    refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))
  end

  test "persisted identity cannot be rebound to another source" do
    %{root: root} = app_instance_rig()
    descriptor = instance(root)
    assert {:ok, _} = AppInstance.ensure_running(descriptor)
    terminate(descriptor)

    assert {:error, :instance_source_mismatch} =
             AppInstance.ensure_running(Map.put(descriptor, "root", root <> "-other"))
  end

  defp restore_storage(nil), do: Application.delete_env(:code_my_spec, :app_instances_root)
  defp restore_storage(value), do: Application.put_env(:code_my_spec, :app_instances_root, value)

  defp terminate(descriptor),
    do: descriptor |> AppInstance.via() |> GenServer.whereis() |> terminate_pid()

  defp terminate_pid(nil), do: :ok

  defp terminate_pid(pid),
    do: DynamicSupervisor.terminate_child(CmsHarness.AppInstancesSupervisor, pid)
end
