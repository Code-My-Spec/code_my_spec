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

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A failing step halts the run instead of pressing on" do
    scenario "the run stops at the failed domain step with later steps untouched" do
      given_ "setup is ready to run and the domain step will fail", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step fails", context do
        ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
          context.view
          |> element("[data-test='start-setup']")
          |> render_click()
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
