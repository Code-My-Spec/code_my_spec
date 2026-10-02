defmodule CodeMySpecSpex.Story973.Criterion8043Spex do
  @moduledoc """
  Story 973 — My app has a working feedback widget
  Criterion 8043 — A down backend degrades the widget, not the site.

  When CodeMySpec is unreachable, Sam's page renders and works normally and
  the widget fails quietly. A third-party script that takes the host page
  down with it is a liability Sam did not sign up for by adding a feedback
  box.

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  probe moved off ProvisioningLive's blocking click into widget's Checks
  tab, behind DiagnosticsPanel, running async via `start_async` — same move
  criterion 613 made for the storage round-trip probe.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Widget`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :widget_on_the_fleet

  defp widget_degradation_done?(html),
    do: not (html =~ ~s(data-test="widget-degradation-probe-panel" data-state="running"))

  spex "A down backend degrades the widget, not the site", criterion: 648 do
    scenario "the page renders normally while the widget fails quietly" do
      # Installed for real, because the criterion is about how an installed
      # widget behaves when its backend is gone. With nothing installed, "the
      # page renders and the widget fails quietly" is satisfied by a page
      # that never had a widget — passing for the wrong reason. The fleet's
      # site carries the widget, and the probe below reads it back off the
      # page rather than trusting that the step ran.
      given_ "the widget is installed on Sam's site", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/widget?tab=checks"
          )

        {:ok, Map.put(context, :view, view)}
      end

      when_ "CodeMySpec is unreachable and a visitor loads the site", context do
        # Unreachable, stated. The site still answers — that is the whole
        # distinction — and its widget reports itself unavailable rather than
        # claiming to work.
        widget_backend_is_down(context)

        context.view
        |> element("[data-test='widget-degradation-probe']")
        |> render_click()

        html =
          await_operation(context.view, &widget_degradation_done?/1, &widget_degradation_done?/1)

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

      then_ "the widget fails quietly rather than claiming to work", context do
        widget_state = context.probe |> Floki.attribute("data-widget-state") |> List.first()

        # The widget is on the page — "absent" would mean the previous
        # assertion passed on a page that simply has no widget to break.
        assert widget_state not in [nil, "", "absent"],
               "expected the probe to find a widget on the page, got #{inspect(widget_state)}"

        # And it does not claim a connection it does not have. This is the
        # negative, deliberately: what the probe fetches is a dead render, and
        # a dead render's state marker reads the same whether the backend is
        # up or down — so "the widget marks itself unavailable" is not
        # something HTTP can establish, and asserting it passed on any page
        # carrying the marker at all.
        #
        # The old pair here also asserted `data-console-errors == "0"`, which
        # the LiveView filled in with a literal "0" on every successful probe.
        # Nothing counted anything; a GET cannot see a console. Watching the
        # widget connect, fail, and stay quiet needs a browser, and belongs in
        # the generated app's own suite — see `Widget.probe_degraded/2`.
        assert widget_state != "connected",
               "expected the page not to claim a live widget connection, got #{inspect(widget_state)}"

        {:ok, context}
      end
    end
  end
end
