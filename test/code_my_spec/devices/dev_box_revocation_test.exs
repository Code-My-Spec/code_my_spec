defmodule CodeMySpec.Devices.DevBoxRevocationTest do
  @moduledoc """
  Story 1131: a box's access tokens belong to it alone, and revoking the box
  ends them and its token without touching another box.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Oauth
  alias CodeMySpec.Workspaces.Runner
  alias ExOauth2Provider.AccessTokens

  setup do
    owner = user_fixture()
    account = account_with_owner_fixture(owner)
    scope = user_scope_fixture(owner, account)
    {:ok, one, one_token} = add(scope, "one")
    {:ok, two, two_token} = add(scope, "two")

    %{scope: scope, owner: owner, one: one, two: two, one_token: one_token, two_token: two_token}
  end

  defp add(scope, name),
    do:
      Devices.add_dev_box(scope, %{"name" => name, "provider" => "local"}, Runner.dev_box(:local))

  test "an access token is tied to its box and expires", %{owner: owner, one: one} do
    {:ok, token} = Oauth.issue_box_token(one, owner, 60)

    assert Oauth.box_token(token) == one.id
    assert token.expires_in == 60

    assert AccessTokens.is_accessible?(
             AccessTokens.get_by_token(token.token, otp_app: :code_my_spec)
           )
  end

  test "revoking a box ends its token and its access tokens, and no other box's", ctx do
    {:ok, one_access} = Oauth.issue_box_token(ctx.one, ctx.owner, 60)
    {:ok, two_access} = Oauth.issue_box_token(ctx.two, ctx.owner, 60)

    assert {:ok, _box} = Devices.revoke_dev_box(ctx.scope, ctx.one.id)
    assert Oauth.revoke_box_tokens(ctx.one.id) == 1

    assert Devices.sign_in_with_token(ctx.one_token) == nil
    assert Devices.active_dev_box(ctx.one.id) == nil

    refute AccessTokens.is_accessible?(
             AccessTokens.get_by_token(one_access.token, otp_app: :code_my_spec)
           )

    assert Devices.sign_in_with_token(ctx.two_token).id == ctx.two.id
    assert Devices.active_dev_box(ctx.two.id).id == ctx.two.id

    assert AccessTokens.is_accessible?(
             AccessTokens.get_by_token(two_access.token, otp_app: :code_my_spec)
           )
  end

  test "only an owner or admin revokes", %{scope: scope, one: one} do
    member = user_fixture()
    _ = member_fixture(member, scope.active_account, :member)
    member_scope = user_scope_fixture(member, scope.active_account)

    assert {:error, :forbidden} = Devices.revoke_dev_box(member_scope, one.id)
    assert Devices.active_dev_box(one.id)
  end

  test "the account hears of a revoke", %{scope: scope, one: one} do
    :ok = Devices.subscribe(scope.active_account_id)
    {:ok, _} = Devices.revoke_dev_box(scope, one.id)
    assert_receive {:dev_box_revoked, id}
    assert id == one.id
  end
end
