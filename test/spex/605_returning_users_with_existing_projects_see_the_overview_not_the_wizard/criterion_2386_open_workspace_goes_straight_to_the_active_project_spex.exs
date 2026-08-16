defmodule CodeMySpecSpex.Story605.Criterion2386Spex do
  @moduledoc """
  Story 605 — Returning users with existing projects see the Overview, not the wizard.
  Criterion 2386 — Open workspace goes straight to the active project.

  The story's point is resuming work without setup ceremony. Landing on /app and
  clicking through to the project you had already selected is that ceremony, one
  step later than the wizard the story removed — so the workspace entry point
  goes where you left off.

  Asserted on the rendered marketing chrome rather than by following the link:
  the defect this guards is the href, and a redirect further down the stack
  would satisfy a navigation test while the button still pointed at /app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The workspace button resumes where you left off" do
    scenario "Open workspace goes straight to the active project" do
      given_ "a project is selected as active", context do
        # given: already true — `setup_active_project` selects one, which is
        # exactly the precondition. Asserted rather than assumed, because the
        # whole criterion turns on the scope carrying it.
        assert context.scope.active_project_id == context.project.id

        {:ok, context}
      end

      when_ "the marketing page is rendered for that user", context do
        conn = Phoenix.ConnTest.get(context.conn, "/")

        {:ok, Map.put(context, :html, Phoenix.ConnTest.html_response(conn, 200))}
      end

      then_ "the workspace button points at that project", context do
        assert context.html =~ ~s|href="/app/projects/#{context.project.id}"|,
               "the button exists to resume work, and /app is one click short of it"

        {:ok, context}
      end

      then_ "it does not point at /app", context do
        refute context.html =~ ~s|href="/app" class="btn btn-primary">Open workspace|,
               "a workspace button that lands on the Overview is the ceremony this story removes"

        {:ok, context}
      end
    end
  end
end
