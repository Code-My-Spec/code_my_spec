defmodule CodeMySpecWeb.ConsoleLiveTest do
  @moduledoc """
  Smoke coverage for step 6's console (held on its own branch, not promoted).

  Just "does every section mount and render" — the console doesn't have
  real spex coverage yet, and isn't meant to until it's reviewed and the
  layout settles. This exists so a WIP commit here doesn't silently stop
  compiling or crash on mount.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp path(project), do: "/app/projects/#{project.id}/console"
  defp resources_path(project), do: "/app/projects/#{project.id}/console/resources"
  defp resource_path(project, key), do: "/app/projects/#{project.id}/console/resources/#{key}"
  defp deploys_path(project), do: "/app/projects/#{project.id}/console/deploys"
  defp secrets_path(project), do: "/app/projects/#{project.id}/console/secrets"
  defp credentials_path(project), do: "/app/projects/#{project.id}/console/credentials"
  defp activity_path(project), do: "/app/projects/#{project.id}/console/activity"
  defp settings_path(project), do: "/app/projects/#{project.id}/console/settings"

  describe "every section mounts" do
    test "overview", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, path(project))
      assert html =~ ~s(data-test="console-overview")
      assert html =~ ~s(data-test="setup-checklist")
    end

    test "resources, grouped per the plan's resource types", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, resources_path(project))
      assert html =~ ~s(data-test="console-resources")

      for test_id <-
            ~w(repository servers dns_domain mail storage_backups publishing widget) do
        assert html =~ ~s(data-resource="#{test_id}")
      end
    end

    test "a resource's detail", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, resource_path(project, :repository))
      assert html =~ ~s(data-test="resource-detail")
      assert html =~ ~s(data-step="repository")
    end

    test "a resource group with no steps for the current environment", %{
      conn: conn,
      project: project
    } do
      # storage and backups are both environment-scoped — unlike server,
      # domain and dns, which are project-wide and would show regardless.
      {:ok, _view, html} =
        live(conn, resource_path(project, :storage_backups) <> "?env=nonexistent")

      assert html =~ ~s(data-test="resource-no-steps")
    end

    test "a made-up resource key reads as not found, not a crash", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, resource_path(project, "not_a_real_group"))
      assert html =~ ~s(data-test="resource-not-found")
    end

    test "deploys", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, deploys_path(project))
      assert html =~ ~s(data-test="console-deploys")
      assert html =~ ~s(data-test="generate-project")
    end

    test "secrets", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, secrets_path(project))
      assert html =~ ~s(data-test="console-secrets")
      assert html =~ ~s(data-test="secret-form")
    end

    test "credentials", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, credentials_path(project))
      assert html =~ ~s(data-test="console-credentials")
      assert html =~ ~s(data-test="credentials-form")
    end

    test "activity", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, activity_path(project))
      assert html =~ ~s(data-test="console-activity-page")
    end

    test "settings", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, settings_path(project))
      assert html =~ ~s(data-test="console-settings")
      assert html =~ ~s(data-test="add-environment-form")
    end
  end

  describe "navigation" do
    test "the sidebar links to every section", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, path(project))

      for test_id <- ~w(overview resources deploys secrets credentials activity settings) do
        assert has_element?(view, "[data-test='console-nav-#{test_id}']")
      end
    end

    test "switching environments patches, not remounts", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, resources_path(project))

      view
      |> element("[data-test='environment-switcher-tab'][data-environment='prod']")
      |> render_click()

      assert_patch(view, resources_path(project) <> "?env=prod")
    end

    test "switching tabs on a resource patches to the tab", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, resource_path(project, :repository))

      view |> element("[data-test='resource-tab-checks']") |> render_click()

      assert has_element?(view, "[data-test='resource-tab-panel'][data-panel='checks']")
    end
  end
end
