defmodule CodeMySpecSpex.Story885.Criterion2320Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2320 — The app's styling stays inside the pane.

  Rule: nothing the app does changes the page Sam is on.

  The generated app ships Tailwind, and Tailwind ships preflight — a global
  reset that reassigns margins, borders and font sizes on bare elements. In a
  shared cascade it does not blend with the host's styles, it replaces them,
  and the visible result is our own page quietly falling apart around a
  preview that looks fine.

  Same mechanism as criterion 2319 and the same limit: whether two stylesheets
  collided is a rendering fact. What a suite can hold is that the app is in a
  document of its own, which is what an iframe is. 885 chose it for exactly
  this pair of problems.

  Surface: the preview page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The app's stylesheet cannot reach the page around it" do
    scenario "The app's styling stays inside the pane" do
      given_ "Sam's app is showing in the pane", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running)

        {:ok, _view, html} = live(context.conn, "/build/preview")

        {:ok, Map.put(context, :html, html)}
      end

      when_ "it renders with its own stylesheet", context do
        document = Floki.parse_document!(context.html)

        {:ok, Map.put(context, :document, document)}
      end

      then_ "the surrounding page still looks the way it did", context do
        assert Floki.find(context.document, "[data-test='preview-pane'] iframe") != [],
               "the app was not given a document of its own, so its Tailwind preflight " <>
                 "shares a cascade with the host and resets the page around it"

        {:ok, context}
      end

      then_ "and the app still looks the way it should", context do
        # Nothing of the target's is inlined into our document — no stylesheet
        # lifted out of it, no style block carrying its rules into our cascade.
        refute Floki.find(context.document, "[data-test='preview-pane'] style") != [],
               "the app's styles were inlined into the host document rather than " <>
                 "staying inside the frame"

        {:ok, context}
      end
    end
  end
end
