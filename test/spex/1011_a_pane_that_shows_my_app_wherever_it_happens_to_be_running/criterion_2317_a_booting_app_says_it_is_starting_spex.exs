defmodule CodeMySpecSpex.Story885.Criterion2317Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2317 — A booting app says it is starting.

  Rule: a target that is still starting says so.

  Starting is the state with a promise attached: something is coming, wait.
  That promise is only worth making when it is true, which is why this is a
  different screen from `:down` — see criterion 2318, which asserts the other
  half of the same distinction.

  The fake decides when the app begins answering, so this observes the
  starting state on purpose rather than racing the boot watcher's wall clock.
  That race is lost on a loaded machine, which is exactly where a preview must
  not flake.

  Surface: the preview page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A pane that is still coming up says so" do
    scenario "A booting app says it is starting" do
      given_ "the app has been asked to start and has not finished", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :starting)

        {:ok, context}
      end

      when_ "he looks at the pane", context do
        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "it says the app is starting", context do
        assert context.html =~ ~r/starting/i,
               "expected the pane to say the app is starting, got: #{context.html}"

        {:ok, context}
      end

      then_ "and it does not look like a failure", context do
        refute context.html =~ ~r/down|failed|error|crashed/i,
               "an app on its way up was reported as a failure"

        {:ok, context}
      end
    end
  end
end
