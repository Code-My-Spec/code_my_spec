defmodule CodeMySpecWeb.ProvisioningLiveTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Sequence, StepRepository}

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp path(project), do: "/app/projects/#{project.id}/provisioning"

  # The page verifies against providers on mount; these tests are about
  # rendering, so the provider's answer is supplied rather than reached for.
  defp stub_verifier(fun) do
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])
    Application.put_env(:code_my_spec, :provisioning_step_opts, Keyword.put(previous, :verify, fun))
    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)
  end

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

    # The steps updated on toggle and the credential panel did not, so the page
    # went on demanding credentials the run no longer needed until a reload.
    # Stale would be forgivable if it were only a list; it is the blocker
    # message, and the Hetzner S3 keys it names cannot be minted through an API
    # — believing it costs a trip to a provider console for nothing.
    #
    # Asserted without reloading on purpose. Criterion 7982 checks the same
    # thing on a freshly mounted page, which is why this survived: the
    # behaviour was always right on mount and always wrong live.
    test "unchecking an option stops it asking for that option's credentials",
         %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, path(project))

      assert html =~ "hetzner_s3_access_key_id",
             "expected object storage keys to be asked for while storage is on"

      html = render_change(view, "toggle_options", %{"options" => %{"domain" => "true"}})

      refute html =~ "hetzner_s3_access_key_id",
             "expected the storage keys to stop being asked for the moment storage is off"

      refute html =~ "hetzner_s3_secret_access_key"

      # The credentials the run still needs are untouched — this narrows the
      # set, it does not clear it.
      assert html =~ "hetzner_api_token"
    end
  end

  describe "a step's state is rendered from what actually happened" do
    # The page re-checks a done step against its provider on mount rather than
    # reading the row back, so the verifier has to say the resource is there —
    # a seeded row alone is exactly what this page deliberately no longer
    # trusts.
    test "a done step shows done", %{conn: conn, project: project, scope: scope} do
      StepRepository.upsert(scope, :repository, %{state: :done, position: 0})
      stub_verifier(fn _scope, _key -> {:ok, :satisfied, []} end)

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ ~r/data-step="repository"[^>]*data-state="done"/
    end

    # The other half of the same behaviour: a resource that has gone from the
    # provider drops back so the next run rebuilds it (criterion 7964).
    test "a done step whose resource is gone drops back to not_started", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :repository, %{state: :done, position: 0})
      stub_verifier(fn _scope, _key -> {:ok, :absent} end)

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ ~r/data-step="repository"[^>]*data-state="not_started"/,
             "a step whose resource is gone kept claiming done"
    end

    # A provider that cannot be reached is not evidence the resource is gone,
    # and treating it as such would un-mark finished work over a timeout.
    test "an unreachable provider leaves the step alone", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :repository, %{state: :done, position: 0})
      stub_verifier(fn _scope, _key -> {:error, :timeout} end)

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ ~r/data-step="repository"[^>]*data-state="done"/,
             "a timeout un-marked a step that was finished"
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

  describe "pasted provider credentials" do
    # Hetzner has no OAuth: project-scoped API tokens, and object-storage keys
    # that exist only in the console. The storage step pauses telling Sam to
    # save them on the project, so there has to be somewhere to do that.
    test "the page offers the credentials Hetzner cannot grant over OAuth", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, path(project))

      for key <- ["hetzner_api_token", "hetzner_s3_access_key_id", "hetzner_s3_secret_access_key"] do
        assert html =~ ~s(data-key="#{key}"), "expected a field for #{key}"
        assert html =~ ~s(data-set="false"), "expected #{key} to report itself unset"
      end
    end

    test "saving a credential records it and reports it set", %{conn: conn, project: project, scope: scope} do
      {:ok, view, _html} = live(conn, path(project))

      html =
        view
        |> form("form[phx-submit='save_credentials']", %{
          "credentials" => %{"hetzner_api_token" => "tok-abc"}
        })
        |> render_submit()

      assert html =~ ~s(data-key="hetzner_api_token")
      assert html =~ ~r/data-key="hetzner_api_token"[^>]*data-set="true"/

      assert {:ok, "tok-abc"} = ProjectSecrets.fetch_value(scope, "hetzner_api_token")
    end

    # The field renders empty for a secret that is already set, because the
    # value is never sent back to the browser. Treating blank as a delete would
    # therefore wipe every other credential each time one was saved.
    test "a blank field leaves an existing credential alone", %{conn: conn, project: project, scope: scope} do
      ProjectSecrets.put_value(scope, "hetzner_api_token", "keep-me")

      {:ok, view, _html} = live(conn, path(project))

      view
      |> form("form[phx-submit='save_credentials']", %{
        "credentials" => %{
          "hetzner_api_token" => "",
          "hetzner_s3_access_key_id" => "new-key"
        }
      })
      |> render_submit()

      assert {:ok, "keep-me"} = ProjectSecrets.fetch_value(scope, "hetzner_api_token")
      assert {:ok, "new-key"} = ProjectSecrets.fetch_value(scope, "hetzner_s3_access_key_id")
    end

    # A secret rendered back into the page is a secret in every browser cache
    # and screenshot from then on.
    test "a stored value is never rendered back", %{conn: conn, project: project, scope: scope} do
      ProjectSecrets.put_value(scope, "hetzner_api_token", "super-secret-value")

      {:ok, _view, html} = live(conn, path(project))

      refute html =~ "super-secret-value"
    end
  end
end
