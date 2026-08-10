defmodule CodeMySpecSpex.Story885.Criterion2318Spex do
  @moduledoc """
  Story 885 — A pane that shows my app, wherever it happens to be running.
  Criterion 2318 — A down app says it is down.

  Rule: a target that is down says it is down, not that it is slow.

  The other half of the distinction criterion 2317 opens. Both states fail to
  answer, so a pane that guessed from the response could only ever show one of
  them — which is why `Workspaces.state/1` is asked rather than inferred, and
  why 885 exists as its own story rather than being folded into the proxy.

  Conflating them is how a broken app reads as a slow one: Sam waits, then
  waits longer, and concludes the tool is sluggish rather than that the thing
  he asked for is not running.

  Surface: the preview page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A pane that is down says so plainly" do
    scenario "A down app says it is down" do
      given_ "the app is down", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :down)

        {:ok, context}
      end

      when_ "he looks at the pane", context do
        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "it says the app is down", context do
        assert context.html =~ ~r/down/i,
               "expected the pane to say the app is down, got: #{context.html}"

        {:ok, context}
      end

      then_ "and it is not the same screen a starting app shows", context do
        refute context.html =~ ~r/starting/i,
               "a stopped app was reported as still coming up, which is how a broken " <>
                 "app reads as a slow one"

        {:ok, context}
      end
    end
  end
end
