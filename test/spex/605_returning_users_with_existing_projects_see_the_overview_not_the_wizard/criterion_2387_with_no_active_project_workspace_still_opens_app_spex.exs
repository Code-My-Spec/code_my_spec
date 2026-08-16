defmodule CodeMySpecSpex.Story605.Criterion2387Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects see the Overview, not the wizard.
  Criterion 2387 — With no active project, workspace still opens /app.

  The other half, and the one that keeps the shortcut honest. Sending someone to
  a project page when they have not chosen a project means guessing which — and
  the guess is invisible, because the page it lands on looks like a project you
  meant to open.

  /app is the correct answer with nothing selected: it is where the account's
  projects are, and where the wizard still lives for an account with none.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "With nothing selected, the workspace button does not guess" do
    scenario "With no active project, workspace still opens /app" do
      given_ "no project is selected as active", context do
        # given: already true — `register_log_in_setup_account` sets up an
        # account and stops there. `setup_active_project` is what would select
        # one, and this scenario is deliberately without it.
        refute context.scope.active_project_id,
               "this scenario is about the unselected case; a selected project would test the other one"

        {:ok, context}
      end

      when_ "the marketing page is rendered for that user", context do
        conn = Phoenix.ConnTest.get(context.conn, "/")

        {:ok, Map.put(context, :html, Phoenix.ConnTest.html_response(conn, 200))}
      end

      then_ "the workspace button points at /app", context do
        assert context.html =~ ~s|href="/app"|,
               "with nothing chosen, the workspace is the account's own page"

        {:ok, context}
      end

      then_ "it does not point at any project", context do
        refute context.html =~ "/app/projects/",
               "landing on a project nobody selected is a guess the reader cannot see"

        {:ok, context}
      end
    end
  end
end
