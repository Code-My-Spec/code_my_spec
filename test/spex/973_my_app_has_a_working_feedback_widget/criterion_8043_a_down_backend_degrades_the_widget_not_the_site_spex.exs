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
  setup :devops_on
  setup :connect_providers
  setup :widget_on_the_fleet

  spex "A down backend degrades the widget, not the site" do
    scenario "the page renders normally while the widget fails quietly" do
      # Installed for real, because the criterion is about how an installed
      # widget behaves when its backend is gone. With nothing installed, "the
      # page renders and the widget fails quietly" is satisfied by a page
      # that never had a widget — passing for the wrong reason. The fleet's
      # site carries the widget, and the probe below reads it back off the
      # page rather than trusting that the step ran.
      given_ "the widget is installed on Sam's site", context do
        {:ok, Map.put(context, :view, mount_provisioning(context))}
      end

      when_ "CodeMySpec is unreachable and a visitor loads the site", context do
        html =
          with_full_cassette @cassette do
            context.view
            |> element("[data-test='widget-degradation-probe']")
            |> render_click()
          end

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
