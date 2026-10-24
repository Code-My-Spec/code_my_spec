defmodule CodeMySpec.AppInstances.Tools.TargetTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AppInstances
  alias CodeMySpec.AppInstances.Tools.Target
  alias CodeMySpec.WorkingCopies

  test "defaults to the selected source and accepts another instance from that source" do
    scope = working_copy_scope_fixture()
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    {:ok, default} = AppInstances.ensure_default(scope, copy)

    {:ok, alternate} =
      AppInstances.create(scope, %{
        working_copy_id: copy.id,
        device_id: copy.device_id,
        source_root: copy.root,
        default: false,
        port_mode: :allocated,
        database_mode: :clone
      })

    assert {:ok, ^default} = Target.own_default(scope, %{scope: scope})
    assert {:ok, ^alternate} = Target.own_default(scope, %{scope: scope}, alternate.id)
  end

  test "refuses an instance from another source checkout" do
    scope = working_copy_scope_fixture()
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    {:ok, foreign} =
      WorkingCopies.issue(scope, nil, label: "another source", device: device_fixture(scope))

    {:ok, foreign} = WorkingCopies.report_root(foreign, "/tmp/target-foreign-source")
    {:ok, foreign_instance} = AppInstances.ensure_default(scope, foreign)

    assert {:error, :instance_not_owned} =
             Target.own_default(scope, %{scope: scope}, foreign_instance.id)

    assert copy.id != foreign.id
  end

  test "does not authorize an instance without an active source checkout" do
    scope = working_copy_scope_fixture()
    copy_scope = %{scope | active_working_copy_id: nil}
    {:ok, source_copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    {:ok, instance} =
      AppInstances.create(scope, %{
        working_copy_id: nil,
        device_id: source_copy.device_id,
        source_root: "/tmp/unattached-instance",
        default: false,
        port_mode: :allocated,
        database_mode: :clone
      })

    assert {:error, :instance_not_owned} =
             Target.own_default(copy_scope, %{scope: copy_scope}, instance.id)
  end
end
