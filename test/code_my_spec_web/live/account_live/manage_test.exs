defmodule CodeMySpecWeb.AccountLive.ManageTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  setup :register_and_log_in_user

  describe "mount" do
    test "renders account management page for owner", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, _manage_live, html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert html =~ account.name
      assert html =~ "Account settings and member management"
      assert html =~ "Account Details"
      assert html =~ "Manage"
    end

    test "renders account management page for admin", %{conn: conn, user: user} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :admin)

      {:ok, _manage_live, html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert html =~ account.name
      assert html =~ "Account Details"
    end

    test "renders account management page for member", %{conn: conn, user: user} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :member)

      {:ok, _manage_live, html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert html =~ account.name
      assert html =~ "Account Details"
    end

    test "redirects when account not found", %{conn: conn} do
      nonexistent_id = Ecto.UUID.generate()

      assert {:error,
              {:redirect, %{to: "/app/accounts", flash: %{"error" => "Account not found"}}}} =
               live(conn, ~p"/app/accounts/#{nonexistent_id}/manage")
    end

    test "redirects when user has no access to account", %{conn: conn} do
      other_user = user_fixture()
      account = account_with_owner_fixture(other_user)

      assert {:error,
              {:redirect, %{to: "/app/accounts", flash: %{"error" => "Account not found"}}}} =
               live(conn, ~p"/app/accounts/#{account.id}/manage")
    end
  end

  describe "account form" do
    test "displays account form with current values", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user, %{name: "My Team"})

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert has_element?(manage_live, "form#account-form")
      assert has_element?(manage_live, "input[value='My Team']")
    end

    test "updates account successfully", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      manage_live
      |> form("#account-form", account: %{name: "Updated Name"})
      |> render_submit()

      assert render(manage_live) =~ "Account updated successfully"
      assert render(manage_live) =~ "Updated Name"
    end

    test "displays validation errors", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      manage_live
      |> form("#account-form", account: %{name: ""})
      |> render_submit()

      assert render(manage_live) =~ "can&#39;t be blank"
    end

    test "validates account form on change", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      manage_live
      |> form("#account-form", account: %{name: ""})
      |> render_change()

      assert render(manage_live) =~ "can&#39;t be blank"
    end
  end

  describe "delete account" do
    test "shows delete button for team accounts", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert has_element?(manage_live, "button", "Delete Account")
    end

    test "deletes account successfully", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      # The trigger button (`Delete Account`) only opens the confirm
      # dialog via `show_confirm/2`; the actual `delete-account` event
      # is pushed from the dialog's confirm button.
      result =
        manage_live
        |> element("#confirm-delete-account [data-role='confirm-confirm']")
        |> render_click()

      assert {:error, {:redirect, %{to: "/app/accounts"}}} = result
    end

    test "deletes account with members (cascade delete)", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      # Add a member - should still allow deletion due to cascade
      member_user = user_fixture()
      member_fixture(member_user, account, :member)

      result =
        manage_live
        |> element("#confirm-delete-account [data-role='confirm-confirm']")
        |> render_click()

      assert {:error, {:redirect, %{to: "/app/accounts"}}} = result
    end

    test "non-owners cannot delete account", %{conn: conn, user: user} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :admin)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert has_element?(manage_live, "button[disabled]", "Delete Account")
    end
  end

  describe "navigation component" do
    test "shows navigation with manage tab active", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert has_element?(manage_live, "a.tab-active", "Manage")
      assert has_element?(manage_live, "a.tab", "Members")
      assert has_element?(manage_live, "a.tab", "Invitations")
    end

    test "shows correct navigation for users who can manage members", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert has_element?(manage_live, "a[href='/app/accounts/#{account.id}/manage']")
      assert has_element?(manage_live, "a[href='/app/accounts/#{account.id}/members']")
      assert has_element?(manage_live, "a[href='/app/accounts/#{account.id}/invitations']")
    end

    test "hides invitations tab for users who cannot manage members", %{conn: conn, user: user} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :member)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      assert has_element?(manage_live, "a[href='/app/accounts/#{account.id}/manage']")
      assert has_element?(manage_live, "a[href='/app/accounts/#{account.id}/members']")
      refute has_element?(manage_live, "a[href='/app/accounts/#{account.id}/invitations']")
    end
  end

  describe "pubsub updates" do
    test "updates account when account is updated via pubsub", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      updated_account = %{account | name: "Updated via PubSub"}
      send(manage_live.pid, {:account_updated, updated_account})

      assert render(manage_live) =~ "Updated via PubSub"
    end
  end

  describe "form behavior" do
    test "submit button is disabled while updating", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      html =
        manage_live
        |> form("#account-form", account: %{name: "Updated Name"})
        |> render_submit()

      assert html =~ "phx-disable-with=\"Updating...\""
    end

    test "form preserves values on validation error", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, manage_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/manage")

      manage_live
      |> form("#account-form", account: %{name: ""})
      |> render_change()

      assert has_element?(manage_live, "input[value='']")
    end
  end
end
