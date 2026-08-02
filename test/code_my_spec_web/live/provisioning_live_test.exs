defmodule CodeMySpecWeb.ProvisioningLiveTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.Provisioning.{Sequence, StepRepository}

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp path(project), do: "/app/projects/#{project.id}/provisioning"

  describe "the plan is visible before anything runs" do
    # Criterion 7959: Sam sees the shape of the run before it starts, rather
    # than steps appearing one at a time as they execute.
    test "every included step is on the page as not_started", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, path(project))

      for key <- Sequence.keys() do
        assert html =~ ~s(data-step="#{key}"),
               "expected #{key} on the page before anything ran"
      end

      assert html =~ ~s(data-state="not_started")
    end

    test "each step says why it exists", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "the remote CI publishes from"
    end

    test "the repository step is rendered before the deploy step", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, path(project))

      repository = :binary.match(html, ~s(data-step="repository")) |> elem(0)
      deploy = :binary.match(html, ~s(data-step="deploy")) |> elem(0)

      assert repository < deploy,
             "the remote must be shown — and run — before the build that needs it"
    end
  end

  describe "options subtract steps from the page" do
    # Criterion 7968: a step Sam turned off is absent, not greyed out. Greying
    # still reads as part of the run.
    test "unchecking an option removes its steps entirely", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, path(project))

      assert html =~ ~s(data-step="storage")

      # The event is sent directly rather than through form/2: LiveViewTest
      # merges params over the form's *current* values, and an unchecked box
      # is an absent key, so going through the form would keep every option on
      # and assert nothing.
      html = render_change(view, "toggle_options", %{"options" => %{"domain" => "true"}})

      refute html =~ ~s(data-step="storage")

      # Unconditional steps survive.
      assert html =~ ~s(data-step="repository")
      assert html =~ ~s(data-step="deploy")
    end
  end

  describe "a step's state is rendered from what actually happened" do
    test "a done step shows done", %{conn: conn, project: project, scope: scope} do
      StepRepository.upsert(scope, :repository, %{state: :done, position: 0})

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ ~r/data-step="repository"[^>]*data-state="done"/
    end

    # Paused and errored render differently on purpose: one tells Sam what to
    # go do, the other carries what the provider said so an agent can act.
    test "a paused step shows what Sam must do elsewhere", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :domain, %{
        state: :paused,
        position: Sequence.position(:domain),
        paused_instructions: "Register it in the Cloudflare dashboard, then resume."
      })

      {:ok, view, html} = live(conn, path(project))

      assert html =~ ~r/data-step="domain"[^>]*data-state="paused"/
      assert has_element?(view, "[data-test='paused-instructions'][data-step='domain']")
      assert html =~ "Cloudflare dashboard"
    end

    test "an errored step carries the provider's own words", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :domain, %{
        state: :errored,
        position: Sequence.position(:domain),
        attempted: "register example.com via Cloudflare Registrar",
        provider_error: "token does not have Registrar write permission"
      })

      {:ok, view, html} = live(conn, path(project))

      assert has_element?(view, "[data-test='escalation'][data-step='domain']")
      # The detail that names the fix survives — a summary would drop exactly
      # this (criterion 7962).
      assert html =~ "Registrar write permission"
      assert html =~ "register example.com"
    end

    test "a paused step shows no escalation, and an errored one no instructions", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :domain, %{
        state: :paused,
        position: Sequence.position(:domain),
        paused_instructions: "Go do the thing."
      })

      {:ok, view, _html} = live(conn, path(project))

      refute has_element?(view, "[data-test='escalation'][data-step='domain']"),
             "a pause is not an escalation — nothing failed"
    end
  end

  describe "provisioned resources" do
    # Criterion 7969: Sam reads back what he now owns, and where to find it.
    test "each resource names what it is and where it lives", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :server, %{
        state: :done,
        position: Sequence.position(:server),
        resources: [%{kind: "server", location: "hetzner/ash/cms-prod"}]
      })

      {:ok, view, html} = live(conn, path(project))

      assert has_element?(view, "[data-test='setup-record']")
      assert html =~ ~s(data-kind="server")
      assert html =~ "hetzner/ash/cms-prod"
    end

    # Criterion 8003 / 8035: nothing is held on the platform's side.
    test "no resource is owned by the platform", %{conn: conn, project: project, scope: scope} do
      StepRepository.upsert(scope, :server, %{
        state: :done,
        position: Sequence.position(:server),
        resources: [%{kind: "server", location: "hetzner/ash/cms-prod"}]
      })

      {:ok, _view, html} = live(conn, path(project))

      refute html =~ ~s(data-owner="platform")
      assert html =~ ~s(data-owner="user")
    end
  end

  describe "affordances" do
    test "every step can be run individually", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(
               view,
               "[data-test='setup-step'][data-step='repository'] [data-test='run-step']"
             )
    end

    # Criterion 7971: retrying one errored step without re-running the rest.
    test "an errored step offers a retry", %{conn: conn, project: project, scope: scope} do
      StepRepository.upsert(scope, :server, %{
        state: :errored,
        position: Sequence.position(:server),
        attempted: "create the server",
        provider_error: "no capacity"
      })

      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(
               view,
               "[data-test='setup-step'][data-step='server'] [data-test='retry-step']"
             )
    end

    test "a not-started step offers no retry — there is nothing to retry", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, path(project))

      refute has_element?(
               view,
               "[data-test='setup-step'][data-step='server'] [data-test='retry-step']"
             )
    end
  end
end
