defmodule CodeMySpec.AuthorizationTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Authorization

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    owner = user_fixture()
    account = account_with_owner_fixture(owner)
    %{owner: owner, account: account}
  end

  describe "authorize/3 :read_account" do
    test "true for any member", %{account: account} do
      member = user_fixture()
      member_fixture(member, account, :member)
      scope = user_scope_fixture(member)

      assert Authorization.authorize(:read_account, scope, account.id) == true
    end

    test "false for a user with no membership", %{account: account} do
      stranger = user_fixture()
      scope = user_scope_fixture(stranger)

      assert Authorization.authorize(:read_account, scope, account.id) == false
    end
  end

  describe "authorize/3 :manage_account" do
    test "true for owner", %{owner: owner, account: account} do
      scope = user_scope_fixture(owner)

      assert Authorization.authorize(:manage_account, scope, account.id) == true
    end

    test "true for admin", %{account: account} do
      admin = user_fixture()
      member_fixture(admin, account, :admin)
      scope = user_scope_fixture(admin)

      assert Authorization.authorize(:manage_account, scope, account.id) == true
    end

    test "false for member", %{account: account} do
      member = user_fixture()
      member_fixture(member, account, :member)
      scope = user_scope_fixture(member)

      assert Authorization.authorize(:manage_account, scope, account.id) == false
    end
  end

  describe "authorize/3 :manage_members" do
    test "true for owner and admin, false for member", %{owner: owner, account: account} do
      admin = user_fixture()
      member_fixture(admin, account, :admin)
      member = user_fixture()
      member_fixture(member, account, :member)

      assert Authorization.authorize(:manage_members, user_scope_fixture(owner), account.id) ==
               true

      assert Authorization.authorize(:manage_members, user_scope_fixture(admin), account.id) ==
               true

      assert Authorization.authorize(:manage_members, user_scope_fixture(member), account.id) ==
               false
    end
  end

  describe "authorize/3 :delete_account" do
    test "true only for owner", %{owner: owner, account: account} do
      admin = user_fixture()
      member_fixture(admin, account, :admin)

      assert Authorization.authorize(:delete_account, user_scope_fixture(owner), account.id) ==
               true

      assert Authorization.authorize(:delete_account, user_scope_fixture(admin), account.id) ==
               false
    end
  end

  describe "authorize/3 unmatched clauses" do
    test "false for an unrecognized action", %{owner: owner, account: account} do
      scope = user_scope_fixture(owner)

      assert Authorization.authorize(:unknown_action, scope, account.id) == false
    end

    test "false when the resource is not a binary id", %{owner: owner} do
      scope = user_scope_fixture(owner)

      assert Authorization.authorize(:read_account, scope, nil) == false
    end
  end

  describe "authorize!/3" do
    test "returns without raising when authorized", %{owner: owner, account: account} do
      scope = user_scope_fixture(owner)

      assert Authorization.authorize!(:read_account, scope, account.id) == nil
    end

    test "raises when unauthorized", %{account: account} do
      stranger = user_fixture()
      scope = user_scope_fixture(stranger)

      assert_raise RuntimeError, ~r/Unauthorized/, fn ->
        Authorization.authorize!(:read_account, scope, account.id)
      end
    end
  end
end
