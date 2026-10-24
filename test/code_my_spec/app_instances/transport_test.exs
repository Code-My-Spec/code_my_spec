defmodule CodeMySpec.AppInstances.TransportTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.AppInstances
  alias CodeMySpec.AppInstances.Transport
  alias CodeMySpec.WorkingCopies

  test "a source with no connected harness is unreachable" do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/no-holder")

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/no-holder")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)

    assert {:error, :harness_not_connected} =
             Transport.request(instance, :ensure_app_running, 100)
  end

  test "an unrooted source can retain an instance but cannot dispatch runtime work" do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, instance} = AppInstances.ensure_default(scope, copy)

    assert is_nil(instance.source_root)
    assert {:error, :invalid_source} = Transport.request(instance, :ensure_app_running, 100)
  end

  test "routes through the checkout harness with the instance descriptor" do
    scope = full_scope_fixture()

    {:ok, main} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/main-served")

    {:ok, _main} = WorkingCopies.report_root(main, "/tmp/main-served")

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/tmp/served")

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/served")
    {:ok, instance} = AppInstances.ensure_default(scope, copy)
    test = self()

    {:ok, holder} =
      Task.start_link(fn ->
        :ok = HarnessRegistry.register_executor(copy.id, self(), copy.root)
        send(test, :registered)

        receive do
          {:"$gen_call", from, {:ensure_app_running, %{instance: descriptor}}} ->
            send(test, {:request, descriptor})
            GenServer.reply(from, {:ok, %{status: "serving", commit: "abc"}})
        end
      end)

    assert_receive :registered, 1_000

    assert {:ok, %{status: "serving", commit: "abc"}} =
             Transport.request(instance, :ensure_app_running, 1_000)

    assert_receive {:request,
                    %{
                      "instance_id" => instance_id,
                      "working_copy_id" => copy_id,
                      "default" => true,
                      "root" => "/tmp/served",
                      "persistent" => false,
                      "port_mode" => "allocated",
                      "database_mode" => "clone",
                      "database_source" => nil,
                      "after_promote" => false
                    }}

    assert instance_id == instance.id
    assert copy_id == copy.id
    Process.exit(holder, :normal)
  end
end
