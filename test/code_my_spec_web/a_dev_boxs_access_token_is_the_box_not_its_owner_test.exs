defmodule CodeMySpecWeb.ADevBoxsAccessTokenIsTheBoxNotItsOwnerTest do
  @moduledoc """
  Story 1131: an access token issued to a dev box is minted against the account
  owner, because OAuth needs a resource owner, but whatever it opens it opens as
  the box. Anywhere `require_oauth_token` accepts it, the scope has no user.
  """
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Oauth
  alias CodeMySpec.Workspaces.Runner

  setup do
    owner = user_fixture()
    account = account_with_owner_fixture(owner)
    scope = user_scope_fixture(owner, account)

    {:ok, box, _token} =
      Devices.add_dev_box(
        scope,
        %{"name" => "cloud-1", "provider" => "local"},
        Runner.dev_box(:local)
      )

    {:ok, access} = Oauth.issue_box_token(box, owner, 60)
    %{box: box, access: access, account: account, scope: scope}
  end

  defp through_oauth(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> CodeMySpecWeb.UserAuth.require_oauth_token([])
  end

  test "the scope is the box's account and carries no user", ctx do
    conn = through_oauth(build_conn(), ctx.access.token)

    refute conn.halted
    assert conn.assigns.box_device.id == ctx.box.id
    assert conn.assigns.current_scope.active_account_id == ctx.account.id
    assert conn.assigns.current_scope.user == nil
  end

  test "once the box is revoked the same token is refused", ctx do
    {:ok, _} = Devices.revoke_dev_box(ctx.scope, ctx.box.id)

    conn = through_oauth(build_conn(), ctx.access.token)

    assert conn.halted
    assert conn.status == 401
  end
end
