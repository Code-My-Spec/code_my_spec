defmodule CodeMySpecSpex.Story885.Criterion2316Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2316 — A story with nothing built shows no pane.

  Rule: the pane is hidden until there is an app to show.

  The absent state is the one a visitor meets first and the easiest to get
  wrong in the direction that costs trust. An empty frame, a spinner, or a
  "preview unavailable" panel all suggest something is coming; nothing is.
  Sam has not asked for an app yet, and the screen should read as though he
  has not.

  Distinct from `:down`, which says a thing that existed has stopped, and from
  `:starting`, which promises it is on its way. Absent promises nothing.

  Surface: the preview page, which is where the pane is hosted.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The pane waits until there is something to show" do
    scenario "A story with nothing built shows no pane" do
      given_ "a project whose app has never been generated", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :absent)

        {:ok, context}
      end

      when_ "the page renders", context do
        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "there is no preview pane", context do
        refute has_element?(context.view, "[data-test='preview-pane']"),
               "a project with nothing built rendered a pane"

        refute context.html =~ "<iframe",
               "an iframe was rendered for an app that does not exist"

        {:ok, context}
      end

      then_ "and nothing suggests one is coming", context do
        refute context.html =~ ~r/starting|loading|preparing|coming/i,
               "the page implied an app was on its way when none had been asked for"

        {:ok, context}
      end
    end
  end
end
