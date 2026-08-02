defmodule CodeMySpecSpex.Story963.Criterion7961Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7961 — A failing step halts the run instead of pressing on.

  When a step fails, setup stops there and every step after it stays not
  started. Pressing on past a failure builds later steps on a broken
  foundation — a deploy against a domain that never got registered.

  The provider's failure is replayed from a cassette; the spec drives the
  page and the app's own Req call is what gets intercepted.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "cloudflare_domain_register_failure"
  @given_cassette "963_7961_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A failing step halts the run instead of pressing on" do
    scenario "the run stops at the failed domain step with later steps untouched" do
      given_ "setup is ready to run and the domain step will fail", context do
        # Before the page mounts. The LiveView reads the project once, at mount;
        # claiming the repository afterwards updates the row but not the socket,
        # so the step still saw a repository belonging to nobody and paused.
        own_repository(context.project)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Hetzner has no OAuth, so its token is pasted per project — without it
        # the server step stops at `hetzner_not_configured` and every claim
        # downstream fails for a reason that is not the one under test. Saving a
        # credential proves it with a real provider call, so it belongs inside a
        # cassette.
        tear_down_after(context.scope, [:server])

        # The repository too, so the next recording starts from one that does not
        # exist — a repository carrying an earlier run's commits rejects a fresh
        # push as non-fast-forward (which is 8184's subject, not this one's).
        tear_down_repository(context.project)

        with_provider_cassette(@given_cassette, fn ->
          paste_provider_credentials(view)
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step fails", context do
        with_provider_cassette(@cassette, fn ->
          context.view
            |> element("[data-test='start-setup']")
            |> render_click()

            # Started, not finished: the click returns as soon as the run
            # begins, so the page is read once the run settles.
            await_provisioning(context.view)
        end)

        {:ok, context}
      end

      then_ "setup stops at the domain step", context do
        html = render(context.view)

        assert html =~ ~r/data-step="domain"[^>]*data-state="errored"/,
               "expected the domain step to be marked errored"

        {:ok, Map.put(context, :html, html)}
      end

      then_ "every step after it is still not started", context do
        parsed = Floki.parse_document!(context.html)
        steps = Floki.find(parsed, "[data-test='setup-step']")

        # Anchor: the plan rendered, so the ordering logic below is real.
        assert steps != [], "expected the plan to render its steps"

        names = Enum.map(steps, &(Floki.attribute(&1, "data-step") |> List.first()))
        states = Enum.map(steps, &(Floki.attribute(&1, "data-state") |> List.first()))

        after_domain =
          Enum.zip(names, states)
          |> Enum.drop_while(fn {name, _} -> name != "domain" end)
          |> Enum.drop(1)

        for {name, state} <- after_domain do
          assert state == "not_started",
                 "expected #{name} to remain not_started after the domain step failed, got #{state}"
        end

        {:ok, context}
      end
    end
  end
end
