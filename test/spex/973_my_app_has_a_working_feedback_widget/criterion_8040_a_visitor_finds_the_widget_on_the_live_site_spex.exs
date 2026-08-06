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

  @cassette "widget_installed_and_rendered"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A visitor finds the widget on the live site" do
    scenario "the widget renders and can be opened on the deployed site" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the widget step has run", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='widget'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "a visitor loading the site finds the widget there", context do
        check =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='widget-render-check']")

        # Anchor: the site was actually loaded and checked.
        assert check != [], "expected the widget step to verify the widget on the live site"

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
end
