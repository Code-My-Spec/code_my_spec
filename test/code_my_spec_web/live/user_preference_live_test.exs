defmodule CodeMySpecWeb.UserPreferenceLiveTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.UserPreferencesFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  setup :register_and_log_in_user

  setup %{scope: scope} do
    account = account_fixture()
    project = project_fixture(scope)

    %{
      create_attrs: %{
        token: "some token",
        active_account_id: account.id,
        active_project_id: project.id
      },
      update_attrs: %{
        token: "some updated token",
        active_account_id: account.id,
        active_project_id: project.id
      },
      account: account,
      project: project
    }
  end

  describe "UserPreference form" do
    test "renders user preferences form", %{conn: conn} do
      {:ok, _form_live, html} = live(conn, ~p"/app/users/preferences")

      assert html =~ "User Preferences"
      assert html =~ "Active account"
      assert html =~ "Active project"
      assert html =~ "Token"
    end

    test "saves user preferences when none exist", %{conn: conn, create_attrs: create_attrs} do
      {:ok, form_live, _html} = live(conn, ~p"/app/users/preferences")

      assert form_live
             |> form("#user_preferences-form", user_preference: create_attrs)
             |> render_submit()

      html = render(form_live)
      assert html =~ "User preferences created successfully"
      assert html =~ "some token"
    end

    test "updates existing user preferences", %{
      conn: conn,
      scope: scope,
      update_attrs: update_attrs
    } do
      user_preference_fixture(scope)
      {:ok, form_live, _html} = live(conn, ~p"/app/users/preferences")

      assert form_live
             |> form("#user_preferences-form", user_preference: update_attrs)
             |> render_submit()

      html = render(form_live)
      assert html =~ "User preferences updated successfully"
      assert html =~ "some updated token"
    end

    test "generates new token", %{conn: conn, scope: scope} do
      user_preference_fixture(scope)
      {:ok, form_live, _html} = live(conn, ~p"/app/users/preferences")

      form_live
      |> element("button", "Generate New Token")
      |> render_click()

      html = render(form_live)
      assert html =~ "Token generated successfully"
    end

    test "validates user preference input", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/app/users/preferences")

      form_live
      |> form("#user_preferences-form", user_preference: %{active_account_id: "invalid"})
      |> render_change()

      # Form should still be rendered even with validation errors
      assert has_element?(form_live, "#user_preferences-form")
    end
  end
end
