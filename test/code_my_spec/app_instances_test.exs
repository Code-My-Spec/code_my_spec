defmodule CodeMySpec.AppInstancesTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.AppInstances
  alias CodeMySpec.WorkingCopies

  test "default instance follows copy root while retaining its initial policy" do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/main-checkout")

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/main-checkout")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)

    assert instance.working_copy_id == copy.id
    assert instance.source_root == "/tmp/main-checkout"
    assert instance.persistent
    assert instance.after_promote
    assert instance.port_mode == :configured
    assert instance.database_mode == :configured

    {:ok, changed} =
      AppInstances.update(scope, instance, %{
        persistent: false,
        source_root: "/tmp/moved-checkout"
      })

    {:ok, refreshed} = AppInstances.ensure_default(scope, %{copy | root: "/tmp/moved-checkout"})
    assert refreshed.id == changed.id
    assert refreshed.source_root == "/tmp/moved-checkout"
    refute refreshed.persistent
  end

  test "a non-main copy gets allocated and cloned policies and a fresh instance id" do
    scope = full_scope_fixture()

    {:ok, main} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/main")

    {:ok, _} = WorkingCopies.report_root(main, "/tmp/main")

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/branch-checkout")

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/branch-checkout")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)

    assert instance.port_mode == :allocated
    assert instance.database_mode == :clone
    refute instance.persistent
    refute instance.after_promote
    assert instance.id != copy.id
    assert AppInstances.for_working_copy(scope, copy).id == instance.id

    assert AppInstances.descriptor(instance) == %{
             "instance_id" => instance.id,
             "working_copy_id" => copy.id,
             "default" => true,
             "root" => "/tmp/branch-checkout",
             "persistent" => false,
             "port_mode" => "allocated",
             "database_mode" => "clone",
             "database_source" => nil,
             "after_promote" => false
           }
  end

  test "stopped instances can be deleted but running ones cannot" do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/checkout")

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/checkout")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)

    {:ok, running} =
      AppInstances.record_status(scope, instance, %{status: "serving", url: "http://localhost"})

    assert {:error, :instance_running} = AppInstances.delete(scope, running)
    {:ok, stopped} = AppInstances.record_status(scope, running, %{status: "down"})
    assert {:ok, _deleted} = AppInstances.delete(scope, stopped)
  end

  test "runtime status changes notify the owning device page after persistence" do
    scope = full_scope_fixture()
    device = device_fixture(scope)
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device, root: "/tmp/preview")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)
    CodeMySpec.Devices.subscribe(scope.active_account_id)

    {:ok, running} = AppInstances.record_status(scope, instance, %{status: "serving"})
    assert_receive {:device_runtime_changed, device_id}
    assert device_id == device.id
    assert AppInstances.for_working_copy(scope, copy).status == "serving"

    {:ok, _} = AppInstances.record_status(scope, running, %{status: "serving"})
    refute_receive {:device_runtime_changed, _}

    {:ok, _} = AppInstances.record_status(scope, running, %{status: "down"})
    assert_receive {:device_runtime_changed, ^device_id}
  end

  test "a copy from another project cannot seed an instance" do
    first_scope = full_scope_fixture()
    second_scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(second_scope, nil,
        device: device_fixture(second_scope),
        root: "/tmp/foreign-checkout"
      )

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/foreign-checkout")

    assert {:error, :invalid_source} = AppInstances.ensure_default(first_scope, copy)

    assert {:error, :scope_mismatch} =
             AppInstances.create(first_scope, %{
               project_id: second_scope.active_project_id,
               source_root: "/tmp/untrusted",
               port_mode: :allocated,
               database_mode: :clone
             })
  end

  test "a standalone instance cannot use a device from another account" do
    scope = full_scope_fixture()
    foreign_scope = full_scope_fixture()
    foreign_device = device_fixture(foreign_scope)

    assert {:error, :device_account_mismatch} =
             AppInstances.create(scope, %{
               device_id: foreign_device.id,
               source_root: "/tmp/standalone",
               port_mode: :allocated,
               database_mode: :clone
             })
  end

  test "an instance cannot be moved to a different source or project" do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/checkout")

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/checkout")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)

    assert {:error, :scope_mismatch} =
             AppInstances.update(scope, instance, %{working_copy_id: nil})

    assert {:error, :scope_mismatch} =
             AppInstances.update(scope, instance, %{project_id: Ecto.UUID.generate()})
  end

  test "a reported runtime cannot reclassify its configured database as disposable" do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/configured-source")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)
    {:ok, instance} = AppInstances.record_status(scope, instance, %{status: "serving"})

    assert {:error, :instance_storage_policy_in_use} =
             AppInstances.update(scope, instance, %{database_mode: :clone})

    assert AppInstances.get(scope, instance.id).database_mode == :configured
    assert {:ok, _} = AppInstances.update(scope, instance, %{persistent: false})
  end

  test "missing instances return an explicit error for preview reports" do
    scope = full_scope_fixture()
    missing = Ecto.UUID.generate()
    assert {:error, :not_found} = AppInstances.record_preview_status(scope, missing, "down")
    assert {:error, :not_found} = AppInstances.clear_preview_tunnel(scope, missing)
  end

  test "update authorizes the persisted instance instead of a stale caller struct" do
    scope = full_scope_fixture()
    foreign_scope = full_scope_fixture()

    {:ok, foreign_instance} =
      AppInstances.create(foreign_scope, %{
        source_root: "/tmp/foreign-instance",
        port_mode: :allocated,
        database_mode: :clone
      })

    forged = %{foreign_instance | project_id: scope.active_project_id}

    assert {:error, :not_found} =
             AppInstances.update(scope, forged, %{persistent: true})

    refute AppInstances.get(foreign_scope, foreign_instance.id).persistent
  end

  test "a stale instance cannot bypass the in-use storage policy guard" do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/main")

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/main")
    {:ok, stale} = AppInstances.ensure_default(scope, copy)
    assert is_nil(stale.checked_at)

    {:ok, _served} = AppInstances.record_status(scope, stale, %{status: "serving"})

    assert {:error, :instance_storage_policy_in_use} =
             AppInstances.update(scope, stale, %{database_mode: :clone})
  end
end
