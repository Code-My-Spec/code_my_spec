defmodule CodeMySpecWeb.AccountsLive.IndexTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.AccountsFixtures

  @create_attrs %{name: "some team name", slug: "some-team-slug"}
  @invalid_attrs %{name: nil, slug: nil}

  setup :register_and_log_in_user

  defp create_account(%{user: user}) do
    account = account_with_owner_fixture(user, %{name: "My Team", slug: "my-team"})
    %{account: account}
  end

  describe "Index" do
    setup [:create_account]

    test "lists the user's accounts", %{conn: conn, account: account} do
      {:ok, _index_live, html} = live(conn, ~p"/app/accounts")

      assert html =~ "Your Accounts"
      assert html =~ account.name
    end

    test "shows create account form", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      refute has_element?(index_live, "#create-account-form")

      assert index_live
             |> element("button", "Create Account")
             |> render_click()

      assert has_element?(index_live, "#create-account-form")
      assert has_element?(index_live, "input[name='account[name]']")
      assert has_element?(index_live, "input[name='account[slug]']")
    end

    test "hides create account form", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      index_live
      |> element("button", "Create Account")
      |> render_click()

      assert has_element?(index_live, "#create-account-form")

      index_live
      |> element("button.btn-sm.btn-ghost[phx-click='show-create-form']")
      |> render_click()

      refute has_element?(index_live, "#create-account-form")
    end

    test "validates account creation", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      index_live
      |> element("button", "Create Account")
      |> render_click()

      assert index_live
             |> form("#create-account-form", account: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"
    end

    test "creates new account", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      index_live
      |> element("button", "Create Account")
      |> render_click()

      assert index_live
             |> form("#create-account-form", account: @create_attrs)
             |> render_submit()

      html = render(index_live)
      assert html =~ "Account created successfully"
      assert html =~ "some team name"
      refute has_element?(index_live, "#create-account-form")
    end

    test "handles form validation errors", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      index_live
      |> element("button", "Create Account")
      |> render_click()

      index_live
      |> form("#create-account-form", account: @invalid_attrs)
      |> render_submit()

      assert has_element?(index_live, "#create-account-form")
      assert render(index_live) =~ "can&#39;t be blank"
    end

    test "cancels account creation", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/app/accounts")

      index_live
      |> element("button", "Create Account")
      |> render_click()

      assert has_element?(index_live, "#create-account-form")

      index_live
      |> element("button", "Cancel")
      |> render_click()

      refute has_element?(index_live, "#create-account-form")
    end

    test "shows accounts in grid", %{conn: conn, account: account} do
      {:ok, _index_live, html} = live(conn, ~p"/app/accounts")

      assert html =~ "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3"
      assert html =~ account.name
      assert html =~ account.slug
    end
  end
end
