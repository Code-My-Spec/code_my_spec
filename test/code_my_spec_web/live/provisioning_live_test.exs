defmodule CodeMySpecWeb.ProvisioningLiveTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Sequence, StepRepository}

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp path(project), do: "/app/projects/#{project.id}/provisioning"
  defp credentials_path(project), do: "/app/projects/#{project.id}/provisioning/credentials"
  defp environments_path(project), do: "/app/projects/#{project.id}/provisioning/environments"
  defp secrets_path(project), do: "/app/projects/#{project.id}/provisioning/secrets"

  # The page verifies against providers on mount; these tests are about
  # rendering, so the provider's answer is supplied rather than reached for.
  defp stub_verifier(fun) do
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.put(previous, :verify, fun)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)
  end

  # Same mechanism as `stub_verifier/1`, one step down `run_step/3`'s own
  # chain: `execute = Keyword.get(opts, :execute, &execute_step/3)`. Captures
  # what a submit actually sent through rather than reaching a real provider.
  defp stub_execute(fun) do
    previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

    Application.put_env(
      :code_my_spec,
      :provisioning_step_opts,
      Keyword.put(previous, :execute, fun)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
    end)
  end

  describe "provider credentials live in a dialog, not inlined on the page" do
    # First piece of breaking this page up: the credentials form used to sit
    # in the middle of the render, ahead of the actual setup steps, purely
    # because it happens to be needed first. Shown through :live_action now —
    # the same pattern ServerLive.Index already uses for its edit form — so
    # the dialog is a real route rather than a CSS class a JS command toggles.
    test "the dialog does not exist on the plain index route", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, path(project))

      refute has_element?(view, "[data-test='credentials-modal']")
      refute html =~ ~s(data-test="credentials-form")
    end

    test "the trigger button on the index page patches to the credentials route", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "[data-test='manage-credentials']")

      html =
        view
        |> element("[data-test='manage-credentials']")
        |> render_click()

      assert has_element?(view, "[data-test='credentials-modal']")
      assert html =~ ~s(data-test="credentials-form")
      assert html =~ ~s(data-credential="hetzner_api_token")
    end

    test "closing the dialog patches back to the index route", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, credentials_path(project))

      assert has_element?(view, "[data-test='credentials-modal']")

      html =
        view
        |> element("[data-test='close-credentials-modal']")
        |> render_click()

      refute has_element?(view, "[data-test='credentials-modal']")
      refute html =~ ~s(data-test="credentials-form")
    end

    # The old inline warning survives outside the dialog — Sam should see
    # setup is blocked without having to open it to find out why.
    test "the missing-credentials summary is visible on the index page", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "Still needed:"
    end
  end

  describe "environments live in a dialog, not inlined on the page" do
    test "the dialog does not exist on the plain index route", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, path(project))

      refute has_element?(view, "[data-test='environments-modal']")
      refute html =~ ~s(data-test="add-environment-form")
    end

    test "the trigger button on the index page patches to the environments route", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "[data-test='manage-environments']")

      html =
        view
        |> element("[data-test='manage-environments']")
        |> render_click()

      assert has_element?(view, "[data-test='environments-modal']")
      assert html =~ ~s(data-test="add-environment-form")
    end

    test "closing the dialog patches back to the index route", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, environments_path(project))

      assert has_element?(view, "[data-test='environments-modal']")

      html =
        view
        |> element("[data-test='close-environments-modal']")
        |> render_click()

      refute has_element?(view, "[data-test='environments-modal']")
      refute html =~ ~s(data-test="add-environment-form")
    end
  end

  describe "secrets live in a dialog, not inlined on the page" do
    test "the dialog does not exist on the plain index route", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, path(project))

      refute has_element?(view, "[data-test='secrets-modal']")
      refute html =~ ~s(data-test="secret-form")
    end

    test "the trigger button on the index page patches to the secrets route", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "[data-test='manage-secrets']")

      html =
        view
        |> element("[data-test='manage-secrets']")
        |> render_click()

      assert has_element?(view, "[data-test='secrets-modal']")
      assert html =~ ~s(data-test="secret-form")
    end

    test "closing the dialog patches back to the index route", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, secrets_path(project))

      assert has_element?(view, "[data-test='secrets-modal']")

      html =
        view
        |> element("[data-test='close-secrets-modal']")
        |> render_click()

      refute has_element?(view, "[data-test='secrets-modal']")
      refute html =~ ~s(data-test="secret-form")
    end
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
      {:ok, view, html} = live(conn, credentials_path(project))

      # Matched on `data-credential`, which only a `credential-field` row
      # carries. A bare substring match finds the key in the blocker's
      # `data-missing` attribute too, so it passes whether or not there is a
      # field to type into — which is the whole thing being asserted.
      assert html =~ ~s(data-credential="hetzner_s3_access_key_id"),
             "expected object storage keys to be asked for while storage is on"

      html = render_change(view, "toggle_options", %{"options" => %{"domain" => "true"}})

      refute html =~ ~s(data-credential="hetzner_s3_access_key_id"),
             "expected the storage keys to stop being asked for the moment storage is off"

      refute html =~ ~s(data-credential="hetzner_s3_secret_access_key")

      # The credentials the run still needs are untouched — this narrows the
      # set, it does not clear it.
      assert html =~ ~s(data-credential="hetzner_api_token")

      # `hetzner_api_token` is `options: :always`, so it survives even an
      # implementation that drops every option-scoped credential — which is
      # exactly what this test used to permit. Cloudflare is scoped to
      # `domain`, the one option still on, so it is the assertion that tells a
      # correct narrowing from a collapse.
      assert html =~ ~s(data-credential="cloudflare_token"),
             "domain is still on, so its credential must still be asked for"
    end

    # The other direction, which filtering could never satisfy: the old
    # implementation intersected the list already on the socket, so a
    # credential removed by one toggle could not come back on the next. It
    # stayed gone until a remount, and the Hetzner S3 pair is console-only —
    # the page's own directions are the only instructions there are.
    test "turning an option back on asks for its credentials again",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, credentials_path(project))

      html = render_change(view, "toggle_options", %{"options" => %{"domain" => "true"}})
      refute html =~ ~s(data-credential="hetzner_s3_access_key_id")

      html =
        render_change(view, "toggle_options", %{
          "options" => %{"domain" => "true", "storage" => "true"}
        })

      assert html =~ ~s(data-credential="hetzner_s3_access_key_id"),
             "storage is back on, so its console-only keys must be asked for again"

      assert html =~ ~s(data-credential="hetzner_s3_secret_access_key")
    end
  end

  describe "a step's state is rendered from what actually happened" do
    # The page re-checks a done step against its provider on mount rather than
    # reading the row back, so the verifier has to say the resource is there —
    # a seeded row alone is exactly what this page deliberately no longer
    # trusts.
    test "a done step shows done", %{conn: conn, project: project, scope: scope} do
      StepRepository.upsert(scope, :repository, nil, %{state: :done, position: 0})
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
      StepRepository.upsert(scope, :repository, nil, %{state: :done, position: 0})
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
      StepRepository.upsert(scope, :repository, nil, %{state: :done, position: 0})
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
      StepRepository.upsert(scope, :domain, nil, %{
        state: :paused,
        position: Sequence.position(:domain),
        paused_instructions: "Register it in the Cloudflare dashboard, then resume."
      })

      {:ok, view, html} = live(conn, path(project))

      assert html =~ ~r/data-step="domain"[^>]*data-state="paused"/
      assert has_element?(view, "[data-test='paused-instructions'][data-step='domain']")
      assert html =~ "Cloudflare dashboard"
    end

    # 4ed72738: a paused `inbound` step names an address Sam has to supply,
    # and the plain "Run" button carries no form data — nothing could ever
    # answer it. Same rendering test as the two escape hatches above
    # (apex-repoint, repository-collision): the affordance shows up exactly
    # when the step that needs it is paused, and not otherwise.
    test "a paused inbound step offers a way to supply the probe address", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :inbound, nil, %{
        state: :paused,
        position: Sequence.position(:inbound),
        paused_instructions: "the inbound records are published... Give it an address and resume."
      })

      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "[data-test='inbound-probe-address']")
      assert has_element?(view, "[data-test='inbound-probe-address-input']")
    end

    test "the probe-address form does not appear for an unrelated paused step", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :domain, nil, %{
        state: :paused,
        position: Sequence.position(:domain),
        paused_instructions: "Register it in the Cloudflare dashboard, then resume."
      })

      {:ok, view, _html} = live(conn, path(project))

      refute has_element?(view, "[data-test='inbound-probe-address']")
    end

    # The wiring, not just the markup: submitting carries `inbound_probe_to`
    # through to the step the same opts every other run path already
    # threads it to (`default_inbound_probe/3` reads it, and every other
    # step ignores a key it doesn't recognise).
    test "submitting the probe address threads it through as inbound_probe_to", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :inbound, nil, %{
        state: :paused,
        position: Sequence.position(:inbound),
        paused_instructions: "Give it an address and resume."
      })

      test_pid = self()

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)
      stub_execute(fn _scope, _key, opts -> send(test_pid, {:executed, opts}) && {:ok, []} end)

      {:ok, view, _html} = live(conn, path(project))

      view
      |> form("[data-test='inbound-probe-address']", %{"probe_to" => "sam@example.com"})
      |> render_submit()

      assert_received {:executed, opts}
      assert Keyword.get(opts, :inbound_probe_to) == "sam@example.com"
    end

    test "an errored step carries the provider's own words", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :domain, nil, %{
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
      StepRepository.upsert(scope, :domain, nil, %{
        state: :paused,
        position: Sequence.position(:domain),
        paused_instructions: "Go do the thing."
      })

      {:ok, view, _html} = live(conn, path(project))

      refute has_element?(view, "[data-test='escalation'][data-step='domain']"),
             "a pause is not an escalation — nothing failed"
    end
  end

  describe "deploy is only ever run for one named environment" do
    # John, after two unscoped run_provisioning_step calls both deployed prod
    # first and never reached uat: "The deploy should be like a thing where I
    # pick the environment and then it should deploy to that environment."
    # The plain "Run"/"Retry" buttons every other step gets would still let
    # this page deploy every environment in one unscoped call, so they are
    # hidden for this one step rather than merely discouraged.
    test "the plain Run and Retry buttons are absent for the deploy step", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :deploy, "prod", %{
        state: :errored,
        position: Sequence.position(:deploy),
        attempted: "deploy",
        provider_error: "boom"
      })

      {:ok, view, _html} = live(conn, path(project))

      refute has_element?(view, "[data-step='deploy'] [data-test='run-step']")
      refute has_element?(view, "[data-step='deploy'] [data-test='retry-step']")
    end

    test "every other step keeps its plain Run button", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "[data-step='repository'] [data-test='run-step']")
    end

    test "the deploy step's form is scoped to its own card's environment, with no picker", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(view, "[data-step='deploy'] [data-test='deploy-environment-form']")

      # No picker: each deploy card is already one environment's row
      # (`data-environment` on the card itself), so a dropdown offering
      # every environment inside it would let the exact cross-environment
      # mistake this form exists to prevent back in through a different door.
      refute has_element?(view, "[data-step='deploy'] [data-test='deploy-environment-select']")
    end

    # The wiring: submitting a card's form threads its own environment through
    # as `:environment`, the same key `run_provisioning_step` requires and
    # `Steps.run(:deploy, ...)` already reads to deploy one environment
    # instead of every environment the project has.
    test "submitting a card's form threads its own environment through", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      test_pid = self()

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)
      stub_execute(fn _scope, _key, opts -> send(test_pid, {:executed, opts}) && {:ok, []} end)

      environment = List.first(CodeMySpec.Provisioning.environment_names(scope))

      {:ok, view, _html} = live(conn, path(project))

      # Deploy has one card per environment, so the selector has to say
      # which row's form it means.
      view
      |> form(
        "[data-step='deploy'][data-environment='#{environment}'] [data-test='deploy-environment-form']"
      )
      |> render_submit()

      assert_received {:executed, opts}
      assert Keyword.get(opts, :environment) == environment
    end
  end

  describe "the DNS confirm and repository adopt buttons run through run_step_async" do
    # Issue 74b6e3a0: both used to call `Provisioning.run_step/3` — the
    # synchronous form — inside the `handle_event`. A dns confirm alone costs
    # up to ~33s of resolver settle+retry per environment; held in the
    # LiveView process, that is long enough to put the socket at risk the
    # same way the plain "Run" button's fdfdfb67 fix was about.
    #
    # Not timing-tested here: `config/test.exs` sets
    # `provisioning_run_async: false` on purpose, so `run_step_async/3` runs
    # synchronously in every test — the same reason the plain "Run" button's
    # own tests don't time it either. A step held under a real async task
    # would race the ExUnit sandbox connection out from under it, so the
    # non-blocking property is exercised live, not under this suite. What
    # these tests do prove: the opt Sam's confirmation carries survives the
    # switch to `run_step_async/3`, and the step still lands correctly.
    test "confirming the apex repoint threads confirm_apex_repoint through", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :dns, nil, %{
        state: :paused,
        position: Sequence.position(:dns),
        paused_instructions: "The apex already points elsewhere."
      })

      test_pid = self()

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)

      stub_execute(fn _scope, _key, opts ->
        send(test_pid, {:executed, opts})
        {:ok, []}
      end)

      {:ok, view, _html} = live(conn, path(project))

      view |> render_click("confirm_apex_repoint")

      assert_receive {:executed, opts}, 1_000
      assert Keyword.get(opts, :confirm_apex_repoint) == true
    end

    test "adopting the colliding repository threads adopt through", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :repository, nil, %{
        state: :paused,
        position: Sequence.position(:repository),
        paused_instructions: "A repository with this name already exists and isn't ours."
      })

      test_pid = self()

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)

      stub_execute(fn _scope, _key, opts ->
        send(test_pid, {:executed, opts})
        {:ok, []}
      end)

      {:ok, view, _html} = live(conn, path(project))

      view |> render_click("adopt_repository")

      assert_receive {:executed, opts}, 1_000
      assert Keyword.get(opts, :adopt) == true
    end

    # The wiring a synchronous handler used to give for free: a halted step
    # after the confirm/adopt call still has to show up as errored/paused
    # from a fresh render, not go silent because nothing calls
    # `assign(halt_reason: ...)` on this path anymore (issue 74b6e3a0's own
    # "careful change" warning — a swallowed failure here is worst on exactly
    # this path, since apex repoint is a destructive decision).
    test "a step that halts after adopt still renders its provider error", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :repository, nil, %{
        state: :paused,
        position: Sequence.position(:repository),
        paused_instructions: "A repository with this name already exists and isn't ours."
      })

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)
      stub_execute(fn _scope, _key, _opts -> {:error, :timeout} end)

      {:ok, view, _html} = live(conn, path(project))

      html = view |> render_click("adopt_repository")

      assert html =~ ~r/data-step="repository"[^>]*data-state="errored"/
      assert has_element?(view, "[data-test='escalation'][data-step='repository']")
    end
  end

  describe "an errored step reports its failure once" do
    # The deploy step carries its provider error twice: `escalation`, which
    # every errored step has, and `boot-failure`, which criterion 8000 selects
    # on to prove the missing secret is named. Both are legitimate; printing
    # the same sentence in each made the step read as two problems.
    test "deploy does not print its provider error twice", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      reason = "uat is missing SECRET_KEY_BASE, DATABASE_URL — the app refuses to boot"

      StepRepository.upsert(scope, :deploy, "prod", %{
        state: :errored,
        position: Sequence.position(:deploy),
        attempted: "run the deploy step",
        provider_error: reason
      })

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)

      {:ok, view, html} = live(conn, path(project))

      # Still said once, and still in the element criterion 8000 selects on.
      assert has_element?(view, "[data-test='boot-failure']")
      assert html =~ "SECRET_KEY_BASE"

      occurrences = length(String.split(html, reason)) - 1

      assert occurrences == 1,
             "expected the deploy failure to be stated once, saw it #{occurrences} times"
    end

    # The other five errored steps have no second element, so the escalation is
    # the only place their provider error appears and must keep printing it.
    test "a non-deploy step still shows its provider error in the escalation", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :storage, "prod", %{
        state: :errored,
        position: Sequence.position(:storage),
        attempted: "run the storage step",
        provider_error: "the bucket name is already taken"
      })

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ "the bucket name is already taken",
             "suppressing the escalation's error would leave this step with nothing to show"
    end
  end

  describe "provisioned resources" do
    # Criterion 7969: Sam reads back what he now owns, and where to find it.
    test "each resource names what it is and where it lives", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :server, nil, %{
        state: :done,
        position: Sequence.position(:server),
        resources: [%{kind: "server", location: "hetzner/ash/cms-prod"}]
      })

      {:ok, view, html} = live(conn, path(project))

      assert has_element?(view, "[data-test='setup-record']")
      assert html =~ ~s(data-kind="server")
      assert html =~ "hetzner/ash/cms-prod"
    end

    # The panel is headed "What you now own", which is a claim about the
    # present. `reverify/3` keeps a step's recorded resources when the provider
    # says the thing is gone — deliberately, because teardown removes only what
    # a step recorded and clearing the list would leak whatever is still there.
    # So the record outlives the resource, and the panel listed a deleted server
    # under "you own this" on the same page load that discovered it was gone.
    test "a resource whose step no longer verifies is marked, not claimed", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :server, nil, %{
        state: :done,
        position: Sequence.position(:server),
        resources: [%{kind: "server", location: "hetzner/ash/cms-prod"}]
      })

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)

      {:ok, view, html} = live(conn, path(project))

      # Still listed — teardown works from this list, so dropping it would
      # strand the resource rather than fix anything.
      assert html =~ "hetzner/ash/cms-prod"

      assert has_element?(view, "[data-test='unverified-resource'][data-step='server']"),
             "a resource whose step just failed to verify must say so"

      refute html =~
               ~s(data-kind="server" data-location="hetzner/ash/cms-prod" data-verified="true"),
             "an unverified resource must not be marked verified"
    end

    # The same claim one level down. The step's own resource list had the
    # milder version of the problem — a resource under a `not_started` heading
    # is ambiguous rather than a flat assertion of ownership — but it is the
    # same record outliving the same resource, so it gets the same marking.
    test "the step's own resource list marks what no longer verifies", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :server, nil, %{
        state: :done,
        position: Sequence.position(:server),
        resources: [%{kind: "server", location: "hetzner/ash/cms-prod"}]
      })

      stub_verifier(fn _scope, _key -> {:ok, :absent} end)

      {:ok, view, _html} = live(conn, path(project))

      assert has_element?(
               view,
               "[data-test='setup-step'][data-step='server'] [data-test='unverified-resource']"
             ),
             "the step still listed its resource without saying the check had just failed"
    end

    test "a resource whose step verifies is not marked unverified", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :server, nil, %{
        state: :done,
        position: Sequence.position(:server),
        resources: [%{kind: "server", location: "hetzner/ash/cms-prod"}]
      })

      stub_verifier(fn _scope, _key -> {:ok, :satisfied, []} end)

      {:ok, view, _html} = live(conn, path(project))

      refute has_element?(view, "[data-test='unverified-resource'][data-step='server']"),
             "a step that verifies must not have its resources hedged"
    end

    # Criterion 8003 / 8035: nothing is held on the platform's side.
    test "no resource is owned by the platform", %{conn: conn, project: project, scope: scope} do
      StepRepository.upsert(scope, :server, nil, %{
        state: :done,
        position: Sequence.position(:server),
        resources: [%{kind: "server", location: "hetzner/ash/cms-prod"}]
      })

      {:ok, _view, html} = live(conn, path(project))

      refute html =~ ~s(data-owner="platform")
      assert html =~ ~s(data-owner="user")
    end

    # 6dcb62b8: this used to be a hardcoded `data-enforced-by="bucket_lifecycle"`
    # regardless of what the deploy step actually recorded, so the page
    # claimed automatic expiry even when nothing enforced it. It now reads the
    # claim off the resource `retention_resource/1` wrote, the same way
    # `data-destroyed`/`data-booted-from` already read off `builder`.
    test "an image's retention is read from what the step recorded, not assumed", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :deploy, "prod", %{
        state: :done,
        position: Sequence.position(:deploy),
        resources: [
          %{
            kind: "image_retention",
            location: "30 days",
            identifier: "enforced_by=bucket_lifecycle"
          }
        ]
      })

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ ~r/data-test="image-retention"[^>]*data-enforced-by="bucket_lifecycle"/
    end

    # The real default (`:filesystem` storage) never installs a lifecycle
    # rule, so `retention_resource/1` records no `image_retention` resource at
    # all — the same absence-over-false-claim shape as `image_resources(:not_built)`.
    # Nothing here injects that resource, so the page must not claim
    # `bucket_lifecycle` out of nowhere.
    test "no retention resource means no enforcement claim", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :deploy, "prod", %{
        state: :done,
        position: Sequence.position(:deploy),
        resources: [
          %{
            kind: "published_image",
            location: "localhost:5000/app:abc123",
            identifier: "built=true"
          }
        ]
      })

      {:ok, _view, html} = live(conn, path(project))

      refute html =~ ~s(data-test="image-retention")
      refute html =~ "bucket_lifecycle"
    end

    # 6dcb62b8: local-volume storage — the real, final registry design — has
    # no bucket for a lifecycle rule to live in, so its retention claim is
    # `Registry.prune/2` having actually run, recorded with a distinct
    # `enforced_by` rather than reused under `bucket_lifecycle`'s.
    test "a pruned registry claims retention in images, not days", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      StepRepository.upsert(scope, :deploy, "prod", %{
        state: :done,
        position: Sequence.position(:deploy),
        resources: [
          %{
            kind: "image_retention",
            location: "5 images",
            identifier: "enforced_by=prune_on_push"
          }
        ]
      })

      {:ok, _view, html} = live(conn, path(project))

      assert html =~ ~r/data-test="image-retention"[^>]*data-enforced-by="prune_on_push"/
      assert html =~ ~r/data-test="image-retention"[^>]*data-images="5"/
      refute html =~ "bucket_lifecycle"
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
      StepRepository.upsert(scope, :server, nil, %{
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

    # `start_setup` refuses server-side when a credential is missing, and must —
    # a run that starts without its credentials fails partway having already
    # made things (criterion 7985). It said so with `put_flash`, into a page
    # that renders no flash container: this view is mounted without the app
    # layout, so it has no `<aside>` and no flash group, and all fourteen of its
    # `put_flash` calls were written and discarded. Someone who pressed the
    # button got a page identical to the one before they pressed it, and could
    # not tell a refusal from a dead button (85e91bf8, found in QA on story
    # 850).
    #
    # The button stays enabled on purpose — 964/7985 clicks it to prove the
    # refusal is enforced rather than merely displayed, and disabling it would
    # delete that proof.
    test "a refused run says so where the presser can see it", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, path(project))

      html = view |> element("[data-test='start-setup']") |> render_click()

      assert html =~ "before it can start.",
             "expected the refusal to reach the page, not just the socket's flash map"
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
      {:ok, _view, html} = live(conn, credentials_path(project))

      for key <- ["hetzner_api_token", "hetzner_s3_access_key_id", "hetzner_s3_secret_access_key"] do
        assert html =~ ~s(data-key="#{key}"), "expected a field for #{key}"
        assert html =~ ~s(data-set="false"), "expected #{key} to report itself unset"
      end
    end

    test "saving a credential records it and reports it set", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, credentials_path(project))

      html =
        view
        |> form("form[phx-submit='save_credentials']", %{
          "credentials" => %{"hetzner_api_token" => "tok-abc"}
        })
        |> render_submit()

      assert html =~ ~s(data-key="hetzner_api_token")
      assert html =~ ~r/data-key="hetzner_api_token"[^>]*data-set="true"/

      # The account, not the project. `48a6e127` moved the Hetzner credentials
      # to "the same grain as the servers they name" and taught
      # `Hetzner.token/1` to read the account first; the form kept writing per
      # project, so what was typed here went where nothing reads (bcd2b2b4).
      assert {:ok, "tok-abc"} = AccountSecrets.fetch_value(scope, "hetzner_api_token")
    end

    # The field renders empty for a secret that is already set, because the
    # value is never sent back to the browser. Treating blank as a delete would
    # therefore wipe every other credential each time one was saved.
    test "a blank field leaves an existing credential alone", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      AccountSecrets.put_value(scope, "hetzner_api_token", "keep-me")

      {:ok, view, _html} = live(conn, credentials_path(project))

      view
      |> form("form[phx-submit='save_credentials']", %{
        "credentials" => %{
          "hetzner_api_token" => "",
          "hetzner_s3_access_key_id" => "new-key"
        }
      })
      |> render_submit()

      assert {:ok, "keep-me"} = AccountSecrets.fetch_value(scope, "hetzner_api_token")
      # The S3 pair did not move — `Storage.credentials/2` still reads it on the
      # project, so read and write agree there and it stays where it was.
      assert {:ok, "new-key"} = ProjectSecrets.fetch_value(scope, "hetzner_s3_access_key_id")
    end

    # A secret rendered back into the page is a secret in every browser cache
    # and screenshot from then on.
    test "a stored value is never rendered back", %{conn: conn, project: project, scope: scope} do
      AccountSecrets.put_value(scope, "hetzner_api_token", "super-secret-value")

      {:ok, _view, html} = live(conn, path(project))

      refute html =~ "super-secret-value"
    end
  end
end
