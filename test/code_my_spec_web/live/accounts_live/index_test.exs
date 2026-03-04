defmodule CodeMySpecWeb.AccountsLive.IndexTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.AccountsFixtures

  @create_attrs %{name: "some team name", slug: "some-team-slug"}
  @invalid_attrs %{name: nil, slug: nil}

  setup :register_and_log_in_user

  defp create_accounts(%{user: user}) do
    personal_account = personal_account_with_owner_fixture(user)
    team_account = account_with_owner_fixture(user, %{name: "My Team", slug: "my-team"})

    %{personal_account: personal_account, team_account: team_account}
  end

  describe "Index" do
    setup [:create_accounts]

    test "lists personal and team accounts", %{
      conn: conn,
      team_account: team_account
    } do
      {:ok, _index_live, html} = live(conn, ~p"/app/accounts")

      assert html =~ "Your Accounts"
      assert html =~ "Personal Account"
      assert html =~ team_account.name
      assert html =~ "My Team"
    end

    test "shows create team account form", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      # Initially form should be hidden
      refute has_element?(index_live, "#create-team-form")

      # Click to show create form
      assert index_live
             |> element("button", "Create Team Account")
             |> render_click()

      # Form should now be visible
      assert has_element?(index_live, "#create-team-form")
      assert has_element?(index_live, "input[name='account[name]']")
      assert has_element?(index_live, "input[name='account[slug]']")
    end

    test "hides create team account form", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      # Show the form first
      index_live
      |> element("button", "Create Team Account")
      |> render_click()

      assert has_element?(index_live, "#create-team-form")

      # Hide the form using the X button
      index_live
      |> element("button.btn-sm.btn-ghost[phx-click='show-create-form']")
      |> render_click()

      refute has_element?(index_live, "#create-team-form")
    end

    test "validates team account creation", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      # Show create form
      index_live
      |> element("button", "Create Team Account")
      |> render_click()

      # Submit with invalid data
      assert index_live
             |> form("#create-team-form", account: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"
    end

    test "creates new team account", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      # Show create form
      index_live
      |> element("button", "Create Team Account")
      |> render_click()

      # Submit valid data
      assert index_live
             |> form("#create-team-form", account: @create_attrs)
             |> render_submit()

      # Check that account was created and form is hidden
      html = render(index_live)
      assert html =~ "Team account created successfully"
      assert html =~ "some team name"
      refute has_element?(index_live, "#create-team-form")
    end

    test "handles form validation errors", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      # Show create form
      index_live
      |> element("button", "Create Team Account")
      |> render_click()

      # Submit with invalid data
      index_live
      |> form("#create-team-form", account: @invalid_attrs)
      |> render_submit()

      # Form should stay visible with errors
      assert has_element?(index_live, "#create-team-form")
      assert render(index_live) =~ "can&#39;t be blank"
    end

    test "cancels team account creation", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      # Show create form
      index_live
      |> element("button", "Create Team Account")
      |> render_click()

      assert has_element?(index_live, "#create-team-form")

      # Cancel form
      index_live
      |> element("button", "Cancel")
      |> render_click()

      # Form should be hidden
      refute has_element?(index_live, "#create-team-form")
    end

    test "shows personal account prominently", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/app/accounts")

      # Personal account should be in a primary colored card
      assert html =~ "card bg-primary text-primary-content"
      assert html =~ "Personal Account"
      assert html =~ "Your personal workspace"
    end

    test "shows team accounts in grid", %{conn: conn, team_account: team_account} do
      {:ok, _index_live, html} = live(conn, ~p"/app/accounts")

      # Team accounts should be in a grid
      assert html =~ "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3"
      assert html =~ team_account.name
      assert html =~ team_account.slug
    end

    test "shows no team accounts section when none exist", %{conn: conn} do
      # Create user without team accounts
      user = CodeMySpec.UsersFixtures.user_fixture()
      _personal_account = personal_account_with_owner_fixture(user)
      conn = log_in_user(conn, user)

      {:ok, _index_live, html} = live(conn, ~p"/app/accounts")

      # Should not show team accounts section
      refute html =~ "Team Accounts"
      refute html =~ "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3"
    end
  end
end
