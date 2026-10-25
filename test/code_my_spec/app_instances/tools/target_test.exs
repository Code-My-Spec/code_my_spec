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

  test "Main controls an explicitly attached instance and loses access when detached" do
    scope = working_copy_scope_fixture()
    {:ok, own} = WorkingCopies.fetch(scope.active_working_copy_id)
    {:ok, foreign} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, foreign} = WorkingCopies.report_root(foreign, "/tmp/attached-target")
    {:ok, instance} = AppInstances.ensure_default(scope, foreign)

    agent =
      Repo.insert!(%CodeMySpec.Agents.Agent{
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        working_copy_id: own.id,
        working_copy: own.root,
        role: :main,
        provider: "openai",
        status: :running
      })

    context = %{scope: scope, agent_id: agent.id}
    assert {:error, :instance_not_owned} = Target.lifecycle(scope, context, instance.id)

    attachment =
      Repo.insert!(%CodeMySpec.AgentAttachments.Attachment{
        agent_id: agent.id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        working_copy_id: foreign.id
      })

    assert {:ok, ^instance} = Target.lifecycle(scope, context, instance.id)
    detached_scope = %{scope | active_working_copy_id: nil}
    assert {:ok, ^instance} = Target.lifecycle(detached_scope, context, instance.id)
    assert {:error, :missing_active_working_copy} = Target.lifecycle(detached_scope, context, nil)

    for role <- [:coding, :qa] do
      agent |> Ecto.Changeset.change(role: role) |> Repo.update!()
      assert {:error, :instance_not_owned} = Target.lifecycle(scope, context, instance.id)
    end

    agent |> Ecto.Changeset.change(role: :main, retired_at: DateTime.utc_now()) |> Repo.update!()
    assert {:error, :instance_not_owned} = Target.lifecycle(scope, context, instance.id)
    agent |> Ecto.Changeset.change(role: :main, retired_at: nil) |> Repo.update!()
    Repo.delete!(attachment)
    assert {:error, :instance_not_owned} = Target.lifecycle(scope, context, instance.id)
  end

  test "lifecycle refuses provisioned, foreign and malformed instances" do
    scope = working_copy_scope_fixture()
    {:ok, env} = CodeMySpec.Environments.put(scope, "prod", %{})

    {:ok, instance} =
      AppInstances.record_deployment(scope, env.id, %{
        confirmed_at: DateTime.utc_now(),
        image: "example/app:latest"
      })

    assert {:error, :provisioned_instance} = Target.lifecycle(scope, %{}, instance.id)
    assert {:error, :not_found} = Target.lifecycle(full_scope_fixture(), %{}, instance.id)
    assert {:error, :not_found} = Target.lifecycle(scope, %{}, "bad")
  end
end
