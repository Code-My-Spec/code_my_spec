defmodule CodeMySpec.Promotion.DeviceSyncTest do
  use CodeMySpecTest.DataCase, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import ExUnit.CaptureLog
  alias CodeMySpec.Promotion.DeviceSync
  alias CodeMySpec.AppInstances
  alias CodeMySpec.BootVersion
  alias CodeMySpec.{Repo, WorkingCopies}

  defmodule App do
    def ensure_app_running(_, _) do
      {:ok, %{status: "serving", serving_commit: Process.get(:serving, "old")}}
    end

    def reload_supported?(_), do: true

    def reload_app(_, _) do
      Process.put(:reloads, Process.get(:reloads, 0) + 1)
      Process.put(:serving, Process.get(:desired))
      ensure_app_running(nil, nil)
    end

    def restart_app(id, timeout) do
      Process.put(:restarts, Process.get(:restarts, 0) + 1)
      reload_app(id, timeout)
    end
  end

  # A restart: true landing restarts the harness with the app, so the restart
  # reply and the confirmation both find the harness gone.
  defmodule GoneApp do
    def ensure_app_running(_, _), do: {:error, :harness_not_connected}
    def reload_supported?(_), do: true

    def restart_app(_, _) do
      Process.put(:restarts, Process.get(:restarts, 0) + 1)
      Process.put(:serving, Process.get(:desired))
      {:error, {:harness_gone, {:shutdown, :draining}}}
    end
  end

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/device/main")

    {:ok, copy} =
      copy
      |> Ecto.Changeset.change(main: true, root: "/device/#{copy.id}")
      |> Repo.update()

    %{scope: scope, copy: copy}
  end

  test "offline destination keeps desired work durable without failing publication", %{
    scope: scope,
    copy: copy
  } do
    assert {:ok, %{"status" => "pending"}} = DeviceSync.request(scope, "one", "develop", "p1")
    assert app_instance(scope, copy).promotion_sync["head"] == "one"
    assert Repo.reload!(scope.active_project).promotion_sync["branch"] == "develop"
  end

  test "dirty destination fails separately, then retry applies once", %{scope: scope, copy: copy} do
    DeviceSync.request(scope, "one", "main", "p1", dispatch: false)

    log =
      capture_log(fn ->
        assert {:ok, %{"status" => "failed"}} =
                 DeviceSync.apply_pending(scope, copy.id,
                   sync: fn _, _, _, _, _ -> {:error, :dirty} end,
                   app: App
                 )
      end)

    # Recorded on the instance alone, a dirty main checkout refused landings
    # for hours unseen.
    assert log =~ "[DeviceSync] #{copy.root} did not take one"
    assert log =~ ":dirty"

    Process.put(:desired, "one")

    assert {:ok, %{"status" => "applied"}} =
             DeviceSync.apply_pending(scope, copy.id, sync: &synced/5, app: App)

    assert Process.get(:reloads) == 1
    DeviceSync.request(scope, "one", "main", "p1", dispatch: false)

    DeviceSync.apply_pending(scope, copy.id,
      sync: fn _, _, _, _, _ -> flunk("already applied") end
    )

    assert Process.get(:reloads) == 1
  end

  test "lost lifecycle reply is verified without rerunning after-promote", %{
    scope: scope,
    copy: copy
  } do
    DeviceSync.request(scope, "one", "main", "p1", dispatch: false)
    Process.put(:serving, "one")

    assert {:ok, %{"status" => "applied"}} =
             DeviceSync.apply_pending(scope, copy.id, sync: &synced/5, app: App)

    assert Process.get(:reloads, 0) == 0
  end

  test "an older completion cannot overwrite a newer desired revision", %{
    scope: scope,
    copy: copy
  } do
    DeviceSync.request(scope, "one", "main", "p1", dispatch: false)
    Process.put(:serving, "one")

    sync = fn _, _, _, _, _ ->
      DeviceSync.request(scope, "two", "main", "p2", dispatch: false)
      {:ok, %{changed_files: []}}
    end

    assert {:ok, %{"head" => "two", "status" => "pending"}} =
             DeviceSync.apply_pending(scope, copy.id, sync: sync, app: App)
  end

  # 04:05Z: a landing on the checkout :4000 runs from was reloaded in place,
  # and the reload hung every request for seven minutes.
  test "a landing that touches what this server has loaded restarts it", %{
    scope: scope,
    copy: copy
  } do
    here = here()
    {:ok, _} = copy |> Ecto.Changeset.change(root: here) |> Repo.update()

    DeviceSync.request(scope, "one", "main", "p1", dispatch: false)
    Process.put(:desired, "one")

    sync = fn _, _, _, _, _ ->
      {:ok, %{changed_files: ["lib/code_my_spec/promotion/device_sync.ex"]}}
    end

    assert {:ok, %{"status" => "applied"}} =
             DeviceSync.apply_pending(scope, copy.id, sync: sync, app: App)

    assert Process.get(:restarts) == 1
  end

  # The reload's own `mix ecto.migrate` waited for the build lock :4000's code
  # reloader held; this server migrates itself before reloading instead.
  test "a reload of this server's checkout migrates in the server, then reloads", %{
    scope: scope,
    copy: copy
  } do
    {:ok, _} = copy |> Ecto.Changeset.change(root: here()) |> Repo.update()

    DeviceSync.request(scope, "one", "main", "p1", dispatch: false)
    Process.put(:desired, "one")
    sync = fn _, _, _, _, _ -> {:ok, %{changed_files: ["test/example_test.exs"]}} end

    assert {:ok, %{"status" => "applied"}} =
             DeviceSync.apply_pending(scope, copy.id, sync: sync, app: App)

    assert Process.get(:reloads) == 1
    assert Process.get(:restarts, 0) == 0
  end

  # Captured at boot, but node-global: another test may have cleared it, and
  # then nothing here is "this server's checkout" (2026-10-26 ejection).
  defp here do
    with nil <- BootVersion.root() do
      BootVersion.capture(File.cwd!())
      BootVersion.root()
    end
  end

  test "a restart the harness cannot confirm while it restarts too stays pending, then applies on rejoin",
       %{scope: scope, copy: copy} do
    DeviceSync.request(scope, "one", "main", "p1", restart: true, dispatch: false)
    Process.put(:desired, "one")

    log =
      capture_log(fn ->
        assert {:ok, %{"status" => "pending"}} =
                 DeviceSync.apply_pending(scope, copy.id, sync: &synced/5, app: GoneApp)
      end)

    assert log =~ "confirming when it rejoins"
    assert Process.get(:restarts) == 1

    # The harness is back and the app is already on the head: no second restart.
    assert {:ok, %{"status" => "applied"}} =
             DeviceSync.apply_pending(scope, copy.id, sync: &synced/5, app: App)

    assert Process.get(:restarts) == 1
  end

  defp synced(_, _, _, _, _), do: {:ok, %{changed_files: ["lib/example.ex"]}}

  test "replaying an older publication cannot regress durable intent", %{scope: scope, copy: copy} do
    assert {:ok, first} = DeviceSync.reserve_sequence(scope)
    assert {:ok, second} = DeviceSync.reserve_sequence(scope)
    assert first < second

    DeviceSync.request(scope, "old", "main", "first",
      publication_sequence: first,
      dispatch: false
    )

    DeviceSync.request(scope, "new", "main", "second",
      publication_sequence: second,
      dispatch: false
    )

    assert {:ok, %{"head" => "new"}} =
             DeviceSync.request(scope, "old", "main", "first",
               publication_sequence: first,
               dispatch: false
             )

    assert app_instance(scope, copy).promotion_sync["head"] == "new"
    assert Repo.reload!(scope.active_project).promotion_sync["head"] == "new"
  end

  test "a missing project reports persistence failure without raising" do
    scope = %CodeMySpec.Users.Scope{active_project_id: Ecto.UUID.generate()}
    assert {:error, :project_not_found} = DeviceSync.request(scope, "head", "main", "id")
  end

  test "sync_working_copy retries failed application without publishing or losing its identity",
       %{scope: scope, copy: copy} do
    DeviceSync.request(scope, "retry-head", "main", "retry-id", dispatch: false)
    DeviceSync.apply_pending(scope, copy.id, sync: fn _, _, _, _, _ -> {:error, :dirty} end)
    assert app_instance(scope, copy).promotion_sync["status"] == "failed"

    assert {:ok, text} =
             CodeMySpec.WorkingCopies.Tools.SyncWorkingCopy.call(
               %{working_copy_id: copy.id},
               %{scope: scope}
             )

    assert text =~ "retry requested"
    assert text =~ "do not promote again"

    assert %{"status" => "pending", "head" => "retry-head", "promotion_id" => "retry-id"} =
             app_instance(scope, copy).promotion_sync
  end

  test "joining the destination resumes an offline publication through its own harness", %{
    scope: scope,
    copy: copy
  } do
    DeviceSync.request(scope, "joined-head", "main", "joined-promotion")
    test = self()

    pid =
      spawn(fn ->
        CodeMySpec.Analysis.HarnessRegistry.register_executor(copy.id, "joined", copy.root)
        send(test, :registered)

        receive do
          {:"$gen_call", from, {:fs_request, "promotion_sync_remote", payload}} ->
            send(test, {:sync_received, payload})
            GenServer.reply(from, {:ok, %{"changed_files" => []}})
        end

        receive do
          {:"$gen_call", from, {:ensure_app_running, _}} ->
            GenServer.reply(from, {:ok, %{status: "serving", serving_commit: "joined-head"}})
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive :registered
    assert :ok = DeviceSync.copy_joined(scope, copy)
    assert_receive {:sync_received, %{"head" => "joined-head"}}, 2_000
    assert_applied(scope, copy, 100)
  end

  defp app_instance(scope, copy), do: AppInstances.for_working_copy(scope, copy.id)

  defp assert_applied(scope, copy, attempts) do
    await_applied(app_instance(scope, copy).promotion_sync["status"], scope, copy, attempts)
  end

  defp await_applied("applied", _scope, _copy, _attempts), do: :ok
  defp await_applied(status, _scope, _copy, 0), do: assert(status == "applied")

  defp await_applied(_status, scope, copy, attempts) do
    Process.sleep(10)
    assert_applied(scope, copy, attempts - 1)
  end
end
