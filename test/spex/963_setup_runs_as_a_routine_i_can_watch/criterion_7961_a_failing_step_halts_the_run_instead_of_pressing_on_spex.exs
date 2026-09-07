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

        step_info = fn step ->
          {step |> Floki.attribute("data-step") |> List.first(),
           step |> Floki.attribute("data-position") |> List.first() |> String.to_integer(),
           step |> Floki.attribute("data-state") |> List.first()}
        end

        rows = Enum.map(steps, step_info)
        {_, domain_position, _} = Enum.find(rows, &match?({"domain", _, _}, &1))

        # By sequence position, not by where the page happens to draw it: the
        # Account/Project/Environment grouping renders steps in a different
        # order than the routine runs them (secrets and the server both run
        # before domain, for instance), so "after" has to mean the run's own
        # order, not the page's.
        after_domain =
          for {name, position, state} <- rows, position > domain_position, do: {name, state}

        for {name, state} <- after_domain do
          assert state == "not_started",
                 "expected #{name} to remain not_started after the domain step failed, got #{state}"
        end

        {:ok, context}
      end
    end
  end
end
