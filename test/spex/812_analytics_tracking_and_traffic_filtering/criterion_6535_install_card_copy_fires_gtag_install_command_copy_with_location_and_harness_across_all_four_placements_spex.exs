defmodule CodeMySpecSpex.Story812.Criterion6535Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6535 — Rule 4 (hybrid): Install-card copy fires
  `gtag('event', 'install_command_copy', ...)` with `location` and
  `harness` across all four placements.

  Hybrid design: install_command_copy is a browser behavior event fired
  by gtag from the copy-button handler. The button hands gtag its
  parameters through `data-event-name` / `data-event-location` /
  `data-event-harness` attributes — so the surface contract this spec
  guards is that all four install-card placements render those
  attributes. (The gtag call itself is browser JS, exercised by browser
  QA, not a spec.)

  The install-page restructure consolidated the placements onto
  `/install` (the homepage CTAs now link there instead of hosting cards):
    - install_page_macos     (server install, macOS tab)
    - install_page_windows   (server install, Windows tab)
    - install_page           (plugin install card)
    - install_page_firstrun  (first-run command)

  Driven through the marketing surface. Fails if a placement is dropped
  or stops carrying its install_command_copy / harness / location markup.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  spex "Install-card copy fires gtag install_command_copy with location + harness across all four placements" do
    scenario "all four install-card placements render install_command_copy with harness + location" do
      given_ "the rendered install page that hosts the install cards", context do
        install = html_response(get(context.conn, "/install"), 200)
        {:ok, Map.put(context, :html, install)}
      end

      then_ "install cards fire install_command_copy carrying the harness param", context do
        assert context.html =~ ~s(data-event-name="install_command_copy")
        assert context.html =~ ~s(data-event-harness="codemyspec-server")
        assert context.html =~ ~s(data-event-harness="codemyspec")
        {:ok, context}
      end

      then_ "the server-install placements are present", context do
        assert context.html =~ ~s(data-event-location="install_page_macos")
        assert context.html =~ ~s(data-event-location="install_page_windows")
        {:ok, context}
      end

      then_ "the plugin and first-run placements are present", context do
        assert context.html =~ ~s(data-event-location="install_page")
        assert context.html =~ ~s(data-event-location="install_page_firstrun")
        {:ok, context}
      end
    end
  end
end
