defmodule CodeMySpecSpex.Story973.Criterion8043Spex do
  @moduledoc """
  Story 973 — My app has a working feedback widget
  Criterion 8043 — A down backend degrades the widget, not the site.

  When CodeMySpec is unreachable, Sam's page renders and works normally and
  the widget fails quietly. A third-party script that takes the host page
  down with it is a liability Sam did not sign up for by adding a feedback
  box.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Widget`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "widget_backend_unreachable_page_still_renders"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A down backend degrades the widget, not the site" do
    scenario "the page renders normally while the widget fails quietly" do
      given_ "the widget is installed on Sam's site", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "CodeMySpec is unreachable and a visitor loads the site", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='widget-degradation-probe']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the page renders and works normally", context do
        probe =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='widget-degradation-result']")

        # Anchor: a probe against the live page actually ran.
        assert probe != [], "expected the degradation probe to be recorded"

        page_status = probe |> Floki.attribute("data-page-status") |> List.first()
        page_usable = probe |> Floki.attribute("data-page-usable") |> List.first()

        assert page_status == "200",
               "expected the host page to still answer 200, got #{inspect(page_status)}"

        assert page_usable == "true",
               "expected the page to remain usable with the backend down"

        {:ok, Map.put(context, :probe, probe)}
      end

      then_ "the widget fails quietly rather than throwing errors at the visitor", context do
        widget_state = context.probe |> Floki.attribute("data-widget-state") |> List.first()
        console_errors = context.probe |> Floki.attribute("data-console-errors") |> List.first()

        assert widget_state == "unavailable",
               "expected the widget to mark itself unavailable, got #{inspect(widget_state)}"

        assert console_errors == "0",
               "expected no errors thrown at the visitor, got #{inspect(console_errors)}"

        {:ok, context}
      end
    end
  end
end
