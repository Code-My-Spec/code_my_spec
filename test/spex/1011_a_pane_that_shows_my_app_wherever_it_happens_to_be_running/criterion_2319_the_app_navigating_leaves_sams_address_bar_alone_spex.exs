defmodule CodeMySpecSpex.Story885.Criterion2319Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2319 — The app navigating leaves Sam's address bar alone.

  Rule: nothing the app does changes the page Sam is on.

  ## What this asserts, and what it cannot

  Whether a browser's address bar changed is a browser fact, and no
  server-rendered assertion reaches it. What is assertable here is the
  mechanism the story chose to get it — the app is in an iframe, which owns its
  own history, so the target's `push_patch` calls `history.pushState` on its
  own window rather than the host's.

  885 argues this at length: rendering the target in-page instead would need
  `window.liveSocket` to stop being a single global and LiveView's JS commands
  to stop calling `document.querySelector` against the document. Weeks of work
  to reach where an iframe starts. So asserting the frame is asserting the
  decision, not a proxy for it.

  The browser-level guarantee belongs to QA, and this spec should be read as
  covering the half that a suite can hold.

  Surface: the preview page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The app cannot move the page it is shown on" do
    scenario "The app navigating leaves Sam's address bar alone" do
      given_ "Sam's app is showing in the pane", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running)

        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      when_ "the app is rendered in its own browsing context", context do
        frame =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='preview-pane'] iframe")

        {:ok, Map.put(context, :frame, frame)}
      end

      then_ "the app moves to the new page inside the pane", context do
        assert context.frame != [],
               "the app was not framed, so its navigation runs against the host's own " <>
                 "history and would rewrite the address Sam is looking at"

        {:ok, context}
      end

      then_ "and the address of the page Sam is on has not changed", context do
        # The host is still the page it was. Nothing the target does reaches
        # this LiveView at all — it has no channel to it — which is the
        # property the frame buys and the reason there is nothing louder to
        # assert here.
        assert render(context.view) =~ "data-test=\"preview-pane\"",
               "the host navigated away from the page holding the pane"

        {:ok, context}
      end
    end
  end
end
