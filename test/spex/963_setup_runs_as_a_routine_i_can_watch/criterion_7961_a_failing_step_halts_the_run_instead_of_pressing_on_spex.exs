defmodule CodeMySpecSpex.Story963.Criterion7961Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7961 — A failing step halts the run instead of pressing on.

  When a step fails, setup stops there and every step after it stays not
  started. Pressing on past a failure builds later steps on a broken
  foundation — a deploy against a domain that never got registered.

  The claim is about the runner, not about Cloudflare: when a step fails,
  the ones after it stay untouched. So the run is scripted — the domain step
  is told to fail — rather than coaxed into failing through a real provider,
  which made this criterion mint a server and a repository to prove something
  neither was involved in.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "A failing step halts the run instead of pressing on" do
    scenario "the run stops at the failed domain step with later steps untouched" do
      given_ "setup is ready to run and the domain step will fail", context do
        context =
          scripted_run(context, %{
            domain: {:error, "the registrar refused: domain unavailable"}
          })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the domain step fails", context do
        context.view |> element("[data-test='start-setup']") |> render_click()

        # Started, not finished: the click returns as soon as the run begins,
        # so the page is read once the run settles.
        await_provisioning(context.view)

        {:ok, context}
      end

      then_ "setup stops at the domain step", context do
        html = render(context.view)

        assert html =~ ~r/data-step="domain"[^>]*data-state="errored"/,
               "expected the domain step to be marked errored; steps: " <>
                 (html
                  |> Floki.parse_document!()
                  |> Floki.find("[data-test='setup-step']")
                  |> Enum.map_join(", ", fn s ->
                    "#{s |> Floki.attribute("data-step") |> List.first()}=#{s |> Floki.attribute("data-state") |> List.first()}"
                  end))

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
