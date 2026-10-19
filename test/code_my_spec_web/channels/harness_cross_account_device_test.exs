defmodule CodeMySpecWeb.HarnessCrossAccountDeviceTest do
  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    scope = full_scope_fixture()
    target = full_scope_fixture()
    member_fixture(scope.user, target.active_account)
    %{scope: scope, target: target}
  end

  test "an announced device joins a project in another membership account", ctx do
    {:ok, device} = Devices.announce(ctx.scope, nil, %{hostname: "cross-account", kind: :local})

    assert {:ok, reply, channel} = join_device(ctx.scope, ctx.target, device.id)
    assert reply.device_id == device.id
    copy = Repo.get!(WorkingCopy, reply.working_copy_id)
    assert copy.device_id == device.id
    assert copy.project_id == ctx.target.active_project_id
    assert copy.root == "/workspace/cross-account"
    assert channel.assigns.scope.active_account_id == ctx.target.active_account_id
    assert Devices.get_device(ctx.scope, device.id).account_id == ctx.scope.active_account_id
    refute Devices.get_device(ctx.target, device.id)
  end

  test "another user's device in an inaccessible account is refused", ctx do
    stranger = full_scope_fixture()
    {:ok, device} = Devices.announce(stranger, nil, %{hostname: "stranger", kind: :local})
    before_count = Repo.aggregate(WorkingCopy, :count)

    assert {:error, %{reason: reason}} = join_device(ctx.scope, ctx.target, device.id)
    assert reason =~ "did not say which machine"
    assert Repo.aggregate(WorkingCopy, :count) == before_count
  end

  test "unknown and malformed device ids are refused", ctx do
    for id <- [Ecto.UUID.generate(), "invalid-device-id"] do
      assert {:error, %{reason: reason}} = join_device(ctx.scope, ctx.target, id)
      assert reason =~ "did not say which machine"
    end
  end

  defp join_device(scope, target, device_id) do
    socket(UserSocket, "cross-account-device", %{scope: scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{target.active_project_id}", %{
      "contract_version" => HarnessProjectChannel.contract_version(),
      "device" => %{"id" => device_id},
      "root" => "/workspace/cross-account",
      "label" => "cross-account regression"
    })
  end
end
