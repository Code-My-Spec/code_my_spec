defmodule CodeMySpecSpex.Story973.Criterion8040Spex do
  @moduledoc """
  Story 973 — My app has a working feedback widget
  Criterion 8040 — A visitor finds the widget on the live site.

  After the widget step runs, a visitor loading Sam's deployed site finds
  the widget present and openable. Installed-but-invisible is the common
  failure — the script tag lands and nothing renders.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Widget`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # The step runs a mix generator in the project's working directory and then
  # fetches the site it was installed on. Both are real here while recording:
  # a committed application to install into, and the fleet's site to fetch.
  setup :widget_on_the_fleet

  spex "A visitor finds the widget on the live site" do
    scenario "the widget renders and can be opened on the deployed site" do
      given_ "Sam is on the setup status page", context do
        # The widget step needs somewhere to install it and a credential to
        # wire — `require_value/2` refuses without either, so the step never
        # reaches the live site and the criterion fails on its premise. Both
        # come from `widget_on_the_fleet`; this was reaching for
        # `publishable_project/2`, which buys a real object-storage bucket to
        # supply one string a widget criterion has no other use for.

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Set after the mount: a domain present at mount makes `load/2` read the
        # mail panel, which calls Resend outside every cassette.
        own_domain(context.project, "c8040.astralbi.com")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the widget step has run", context do
        # `with_full_cassette` rather than the HTTP one alone: this step is
        # half subprocess and half HTTP — the generator runs through
        # `System.cmd`, the presence check through Req — and recording only
        # the HTTP half leaves the generator running for real on every replay.
        html = CodeMySpecSpex.Case.run_step_interaction(context.view, :widget, "prod")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "a visitor loading the site finds the widget there", context do
        check =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='widget-render-check']")

        # Anchor: the site was actually loaded and checked.
        assert check != [],
               "expected the widget step to verify the widget on the live site. " <>
                 diagnose(context.html)

        status = check |> Floki.attribute("data-status") |> List.first()
        present = check |> Floki.attribute("data-widget-present") |> List.first()

        assert status == "200",
               "expected the deployed site to answer, got #{inspect(status)}"

        assert present == "true",
               "expected the widget to be present on the rendered page"

        {:ok, Map.put(context, :check, check)}
      end

      then_ "it can be opened rather than merely being in the markup", context do
        openable = context.check |> Floki.attribute("data-widget-openable") |> List.first()

        assert openable == "true",
               "expected the widget to actually open — a script tag that renders nothing is not installed"

        {:ok, context}
      end
    end
  end

  # What the widget step reported, for when the render check is missing and the
  # interesting question is why it never got that far.
  defp diagnose(html) do
    step =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-test='setup-step'][data-step='widget']")

    state = step |> Floki.attribute("data-state") |> List.first()
    detail = step |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)

    "widget step state=#{inspect(state)} detail=#{inspect(detail)}"
  end
end
