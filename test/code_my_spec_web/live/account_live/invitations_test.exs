defmodule CodeMySpecWeb.AccountLive.InvitationsTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.InvitationsFixtures
  import CodeMySpec.UserPreferencesFixtures

  setup :register_and_log_in_user

  describe "mount" do
    test "renders invitations page for owner", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, _invitations_live, html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      assert html =~ account.name
      assert html =~ "Account settings and member management"
      assert html =~ "Invitations"
      assert html =~ "Invite Member"
    end

    test "renders invitations page for admin", %{conn: conn, user: user} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :admin)

      {:ok, _invitations_live, html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      assert html =~ account.name
      assert html =~ "Invitations"
      assert html =~ "Invite Member"
    end

    test "renders invitations page for member but hides invite functionality", %{
      conn: conn,
      user: user
    } do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :member)

      {:ok, _invitations_live, html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      assert html =~ account.name
      assert html =~ "Invitations"
      refute html =~ "Invite Member"
    end

    test "redirects when account not found", %{conn: conn} do
      nonexistent_id = Ecto.UUID.generate()

      assert {:error,
              {:redirect, %{to: "/app/accounts", flash: %{"error" => "Account not found"}}}} =
               live(conn, ~p"/app/accounts/#{nonexistent_id}/invitations")
    end

    test "redirects when user has no access to account", %{conn: conn} do
      other_user = user_fixture()
      account = account_with_owner_fixture(other_user)

      assert {:error,
              {:redirect, %{to: "/app/accounts", flash: %{"error" => "Account not found"}}}} =
               live(conn, ~p"/app/accounts/#{account.id}/invitations")
    end
  end

  describe "pending invitations display" do
    test "displays pending invitations", %{conn: conn, user: user, scope: scope} do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})
      invitation = invitation_fixture(account, user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      assert has_element?(invitations_live, "td", invitation.email)
      assert has_element?(invitations_live, "td", to_string(invitation.role))
      assert has_element?(invitations_live, "td", user.email)
    end

    test "displays no invitations message when empty", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      assert has_element?(invitations_live, "div", "No pending invitations")
    end

    test "shows cancel button for pending invitations", %{conn: conn, user: user, scope: scope} do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})
      invitation = invitation_fixture(account, user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      assert has_element?(
               invitations_live,
               "button[phx-value-invitation-id='#{invitation.id}']",
               "Cancel"
             )
    end

    test "does not show cancel button for expired invitations", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})
      expired_invitation = expired_invitation_fixture(account, user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      refute has_element?(
               invitations_live,
               "button[phx-value-invitation-id='#{expired_invitation.id}']",
               "Cancel"
             )
    end

    test "does not show cancel button for non-admins", %{conn: conn, user: user, scope: scope} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :member)
      user_preference_fixture(scope, %{active_account_id: account.id})
      invitation = invitation_fixture(account, owner)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      refute has_element?(
               invitations_live,
               "button[phx-value-invitation-id='#{invitation.id}']",
               "Cancel"
             )
    end
  end

  describe "invite form" do
    test "shows invite form when clicked", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button", "Invite Member")
      |> render_click()

      assert has_element?(invitations_live, "form#invite-form")
      assert has_element?(invitations_live, "input[name='invitation[email]']")
      assert has_element?(invitations_live, "select[name='invitation[role]']")
      assert has_element?(invitations_live, "button", "Send Invitation")
      assert has_element?(invitations_live, "button", "Cancel")
    end

    test "hides invite form when cancelled", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button", "Invite Member")
      |> render_click()

      assert has_element?(invitations_live, "form#invite-form")

      invitations_live
      |> element("button", "Cancel")
      |> render_click()

      refute has_element?(invitations_live, "form#invite-form")
    end

    test "validates invitation form", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button", "Invite Member")
      |> render_click()

      invitations_live
      |> form("#invite-form", invitation: %{email: "invalid-email", role: "member"})
      |> render_change()

      assert render(invitations_live) =~ "has invalid format"
    end

    test "sends invitation successfully", %{conn: conn, user: user, scope: scope} do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button", "Invite Member")
      |> render_click()

      invitations_live
      |> form("#invite-form", invitation: %{email: "test@example.com", role: "member"})
      |> render_submit()

      assert render(invitations_live) =~ "Invitation sent successfully"
      assert has_element?(invitations_live, "td", "test@example.com")
      refute has_element?(invitations_live, "form#invite-form")
    end

    test "displays error when invitation fails", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)
      existing_member = user_fixture()
      member_fixture(existing_member, account, :member)

      # Check if user has access
      member_scope = %CodeMySpec.Users.Scope{user: existing_member}
      assert CodeMySpec.Accounts.user_has_account_access?(member_scope, account.id)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button", "Invite Member")
      |> render_click()

      invitations_live
      |> form("#invite-form", invitation: %{email: existing_member.email, role: "member"})
      |> render_submit()

      html = render(invitations_live)

      assert has_element?(invitations_live, "form#invite-form"),
             "expected the invite form to remain so the error stays visible"

      assert html =~ "User already has access to this account",
             "expected the duplicate-member error from Invitations.invite_user/4 " <>
               "to render on the form"
    end

    test "non-admins cannot see invite form", %{conn: conn, user: user} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :member)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      refute has_element?(invitations_live, "button", "Invite Member")
    end
  end

  describe "cancel invitation" do
    test "cancels invitation successfully", %{conn: conn, user: user, scope: scope} do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})
      invitation = invitation_fixture(account, user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button[phx-value-invitation-id='#{invitation.id}']", "Cancel")
      |> render_click()

      assert render(invitations_live) =~ "Invitation cancelled successfully"
      refute has_element?(invitations_live, "td", invitation.email)
    end

    test "displays error when cancellation fails", %{conn: conn, user: user, scope: scope} do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})
      invitation_fixture(account, user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      # Send the cancel message directly to simulate cancelling a non-existent invitation
      send(invitations_live.pid, {:cancel_invitation, 999_999})

      assert render(invitations_live) =~ "Failed to cancel invitation"
    end

    test "admin can cancel invitations", %{conn: conn, user: user, scope: scope} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :admin)
      user_preference_fixture(scope, %{active_account_id: account.id})
      invitation = invitation_fixture(account, owner)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button[phx-value-invitation-id='#{invitation.id}']", "Cancel")
      |> render_click()

      assert render(invitations_live) =~ "Invitation cancelled successfully"
    end
  end

  describe "navigation" do
    test "displays navigation tabs", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      assert has_element?(invitations_live, "a.tab-active", "Invitations")

      assert has_element?(
               invitations_live,
               "a[href='/app/accounts/#{account.id}/manage']",
               "Manage"
             )

      assert has_element?(
               invitations_live,
               "a[href='/app/accounts/#{account.id}/members']",
               "Members"
             )
    end

    test "highlights invitations tab as active", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      assert has_element?(invitations_live, "a.tab-active", "Invitations")
      refute has_element?(invitations_live, "a.tab-active", "Manage")
      refute has_element?(invitations_live, "a.tab-active", "Members")
    end

    test "hides invitations tab for non-admins", %{conn: conn, user: user} do
      owner = user_fixture()
      account = account_with_owner_fixture(owner)
      member_fixture(user, account, :member)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      refute has_element?(invitations_live, "a", "Invitations")
    end
  end

  describe "real-time updates" do
    test "updates invitation list when new invitation created", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      # Simulate invitation creation via PubSub
      invitation = invitation_fixture(account, user)
      send(invitations_live.pid, {:created, invitation})

      assert render(invitations_live) =~ invitation.email
    end

    test "updates invitation list when invitation cancelled", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)
      invitation = invitation_fixture(account, user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      # Simulate invitation cancellation via PubSub
      cancelled_invitation = %{invitation | cancelled_at: DateTime.utc_now()}
      send(invitations_live.pid, {:updated, cancelled_invitation})

      assert has_element?(invitations_live, "td", invitation.email)
    end

    test "updates account info when account updated", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      # Simulate account update via PubSub
      updated_account = %{account | name: "Updated Account Name"}
      send(invitations_live.pid, {:account_updated, updated_account})

      assert render(invitations_live) =~ "Updated Account Name"
    end
  end

  describe "expired invitations" do
    test "does not show expired invitations in pending list", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})
      expired_invitation = expired_invitation_fixture(account, user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      # Expired invitations should not be displayed in the pending invitations list
      refute has_element?(invitations_live, "td", expired_invitation.email)
      assert has_element?(invitations_live, "div", "No pending invitations")
    end

    test "does not show cancel button for expired invitations", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})
      expired_invitation = expired_invitation_fixture(account, user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      refute has_element?(
               invitations_live,
               "button[phx-value-invitation-id='#{expired_invitation.id}']"
             )
    end
  end

  describe "role selection" do
    test "shows all available roles in select", %{conn: conn, user: user} do
      account = account_with_owner_fixture(user)

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button", "Invite Member")
      |> render_click()

      assert has_element?(invitations_live, "option[value='member']", "Member")
      assert has_element?(invitations_live, "option[value='admin']", "Admin")
      assert has_element?(invitations_live, "option[value='owner']", "Owner")
    end

    test "can invite users with different roles", %{conn: conn, user: user, scope: scope} do
      account = account_with_owner_fixture(user)
      user_preference_fixture(scope, %{active_account_id: account.id})

      {:ok, invitations_live, _html} = live(conn, ~p"/app/accounts/#{account.id}/invitations")

      invitations_live
      |> element("button", "Invite Member")
      |> render_click()

      invitations_live
      |> form("#invite-form", invitation: %{email: "admin@example.com", role: "admin"})
      |> render_submit()

      assert render(invitations_live) =~ "Invitation sent successfully"
      assert has_element?(invitations_live, "td", "admin@example.com")
      assert has_element?(invitations_live, "td", "admin")
    end
  end
end
