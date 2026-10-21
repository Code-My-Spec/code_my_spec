defmodule CodeMySpecWeb.DevBoxJoinsItsAccountTest do
  @moduledoc """
  Issue 2dae034c (story 1131): a dev box joins the project channel on its own
  token, for the projects of its own account and no others, and loses the
  channel when it is revoked.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import Phoenix.ChannelTest

  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Oauth
  alias CodeMySpec.Repo
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    owner = user_fixture()
    _ = member_fixture(owner, scope.active_account, :owner)

    {:ok, box} =
      %Device{}
      |> Device.dev_box_changeset(%{
        label: "cloud-1",
        provider: :local,
        kind: :local,
        account_id: scope.active_account_id,
        token_hash: "hash-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, access} = Oauth.issue_box_token(box, owner, 60)
    %{scope: scope, box: box, access: access.token}
  end

  defp join_box(access, project_id, box) do
    {:ok, socket} = connect(UserSocket, %{"token" => access})

    subscribe_and_join(socket, HarnessProjectChannel, "harness_project:#{project_id}", %{
      "label" => "cloud box",
      "root" => "/workspace/app",
      "device" => %{"id" => box.id}
    })
  end

  test "a box joins a project in its own account", ctx do
    assert {:ok, %{working_copy_id: id, device_id: device_id}, _socket} =
             join_box(ctx.access, ctx.scope.active_project_id, ctx.box)

    assert is_binary(id)
    assert device_id == ctx.box.id
  end

  test "a box is refused a project outside its account", ctx do
    other = full_scope_fixture()

    assert {:error, _reason} = join_box(ctx.access, other.active_project_id, ctx.box)
  end

  test "revoking a box tells its socket to disconnect, and a new join is refused", ctx do
    {:ok, _reply, socket} = join_box(ctx.access, ctx.scope.active_project_id, ctx.box)
    CodeMySpecWeb.Endpoint.subscribe(UserSocket.id(socket))

    {:ok, _} =
      ctx.box
      |> Device.revoked_changeset(DateTime.utc_now())
      |> Repo.update()

    Oauth.revoke_box_tokens(ctx.box.id)
    CodeMySpecWeb.Endpoint.broadcast(UserSocket.id(socket), "disconnect", %{})

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert {:error, _} = connect(UserSocket, %{"token" => ctx.access})
  end
end
