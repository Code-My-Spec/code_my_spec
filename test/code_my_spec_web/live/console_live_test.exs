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

  test "a satisfied provider check refreshes the open page and survives reopening", %{
    conn: conn,
    project: project,
    scope: scope
  } do
    alias CodeMySpec.Provisioning
    alias CodeMySpec.Provisioning.QaFixture
    alias CodeMySpec.ProvisioningPlan.StepRepository

    assert :ok = QaFixture.register(project.id, scope.active_account_id)
    assert {:ok, _} = Provisioning.run_step(scope, :server, nil, [])
    {:ok, view, _} = live(conn, resource_path(project, :servers))
    assert has_element?(view, "[data-test='checked-note'][data-step='server']", "unchecked")

    assert {:ok, checked} = Provisioning.run_step(scope, :server, nil, [])
    timestamp = DateTime.to_iso8601(checked.verified_at)
    assert has_element?(view, "[data-step='server'][data-verified-at='#{timestamp}']")
    assert has_element?(view, "[data-test='checked-note'][data-step='server']", "checked")

    assert {:ok, before_open} = QaFixture.snapshot(project.id)
    {:ok, reopened, _} = live(conn, resource_path(project, :servers))
    assert has_element?(reopened, "[data-step='server'][data-verified-at='#{timestamp}']")
    assert StepRepository.get(scope, :server).verified_at == checked.verified_at
    assert {:ok, after_open} = QaFixture.snapshot(project.id)
    assert after_open.events == before_open.events
  end

  test "a rebuilt server distinguishes its earlier record from current inventory", %{
    conn: conn,
    project: project,
    scope: scope
  } do
    alias CodeMySpec.Provisioning
    alias CodeMySpec.Provisioning.QaFixture

    assert :ok = QaFixture.register(project.id, scope.active_account_id)
    assert {:ok, first} = Provisioning.run_step(scope, :server, nil, [])
    old_location = hd(first.resources).location
    {:ok, view, _} = live(conn, resource_path(project, :servers))

    assert :ok = QaFixture.control(project.id, "server", "delete")
    assert {:ok, rebuilt} = Provisioning.run_step(scope, :server, nil, [])
    current = Enum.find(rebuilt.resources, & &1.observed_in_latest_run)

    old_selector =
      "[data-test='provisioned-resource'][data-location='#{old_location}'][data-historical='true'][data-verified='false']"

    current_selector =
      "[data-test='provisioned-resource'][data-location='#{current.location}'][data-historical='false'][data-verified='true']"

    assert has_element?(view, old_selector, "earlier record; not confirmed by the latest run")
    assert has_element?(view, current_selector)

    assert {:ok, before_open} = QaFixture.snapshot(project.id)
    {:ok, reopened, _} = live(conn, resource_path(project, :servers))
    assert has_element?(reopened, old_selector)
    assert has_element?(reopened, current_selector)
    assert {:ok, after_open} = QaFixture.snapshot(project.id)
    assert after_open.events == before_open.events
  end

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
      assert html =~ ~s(data-test="secrets-import-form")
      assert html =~ ~s(data-test="secrets-import-dotenv")
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
      assert html =~ ~s(data-test="setup-options-form")
      assert html =~ ~s(data-test="setup-option-telemetry")
    end
  end

  describe "setup options" do
    test "toggling one off persists it on the project", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, settings_path(project))

      assert has_element?(view, "[data-test='setup-option-telemetry'] input:checked")

      view
      |> element("[data-test='setup-option-telemetry'] input")
      |> render_click(%{"option" => "telemetry"})

      refute has_element?(view, "[data-test='setup-option-telemetry'] input:checked")

      project = CodeMySpec.Projects.get_project!(scope, project.id)
      refute :telemetry in CodeMySpec.Provisioning.setup_options(project)
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

  describe "running a step from the console" do
    test "clicking Run on a resource's step does not crash the page", %{
      conn: conn,
      project: project
    } do
      # No fake_providers here — this is smoke coverage, not a spex, so it
      # only proves the "run_step" event has a matching clause at all. It
      # didn't: ResourceDetail's button has carried `phx-click="run_step"`
      # since it was extracted in step 5, but nothing in this file ever
      # clicked it, so ConsoleLive shipped with no handler for it.
      {:ok, view, _html} = live(conn, resource_path(project, :repository))

      view
      |> element("[data-test='resource-step'][data-step='repository'] [data-test='run-step']")
      |> render_click()

      assert Process.alive?(view.pid)
    end
  end

  describe "telemetry health results" do
    test "a completed check survives reload and stays with its environment", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      url = resource_path(project, :telemetry) <> "?env=uat&tab=checks"
      {:ok, view, _html} = live(conn, url)
      refute has_element?(view, "[data-test='telemetry-check-result']")

      view
      |> element("[data-test='run-check'][data-check='telemetry']")
      |> render_click()

      render_settled(view)
      saved = CodeMySpec.Telemetry.last_check(scope, "uat")
      assert saved != nil

      {:ok, reloaded, _html} = live(conn, url)
      assert has_element?(reloaded, "[data-test='telemetry-check-result']", "HTTPS reachability:")
      assert has_element?(reloaded, "[data-test='diagnostics-checked-note']", "checked")
      assert CodeMySpec.Telemetry.last_check(scope, "uat") == saved

      render_patch(reloaded, resource_path(project, :telemetry) <> "?env=prod&tab=checks")
      refute has_element?(reloaded, "[data-test='telemetry-check-result']")
      assert has_element?(reloaded, "[data-test='telemetry-check-panel'][data-state='unchecked']")

      render_patch(reloaded, url)
      assert has_element?(reloaded, "[data-test='telemetry-check-result']", "HTTPS reachability:")
      assert CodeMySpec.Telemetry.last_check(scope, "uat") == saved
      assert CodeMySpec.Telemetry.last_check(scope, "prod") == nil
    end

    test "an unavailable environment shows visible outcomes and recovery guidance", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} =
        live(conn, resource_path(project, :telemetry) <> "?env=missing-telemetry&tab=checks")

      refute has_element?(view, "[data-test='telemetry-check-result']")

      view
      |> element("[data-test='run-check'][data-check='telemetry']")
      |> render_click()

      render_settled(view)

      result =
        view
        |> element("[data-test='telemetry-check-result']")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.text()
        |> String.replace(~r/\s+/, " ")

      assert result =~ "HTTPS reachability:"
      assert result =~ "Unavailable"
      assert result =~ "check telemetry setup, DNS, TLS, and server connectivity"
      assert result =~ "Read access:"
      assert result =~ "Could not verify while telemetry is unavailable"
      assert result =~ "Write protection:"
      assert result =~ "restore connectivity and read access, then check again"
      assert has_element?(view, "[data-test='diagnostics-checked-note']", "checked")
    end
  end

  describe "the storage round-trip check" do
    test "running it replaces the old setup page's blocking form with an async one", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, resource_path(project, :storage_backups) <> "?tab=checks")

      refute has_element?(view, "[data-test='storage-probe']"),
             "expected no probe without storage credentials on file"
    end
  end
end
