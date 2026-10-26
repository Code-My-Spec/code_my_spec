defmodule CodeMySpecSpex.Story1030.Criterion1114Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1114 — An app that is still coming up is not reported as broken.

  Rule: `Workspaces.state/1` tells apart "not yet answering" from "answered
  badly" — `from_serving(:down) -> :starting`, `from_serving(:erroring) ->
  :broken`. Both look the same from outside (nothing useful comes back
  either way), which is exactly why the state is asked of the runner rather
  than inferred from the response: an app a few seconds from serving and an
  app actually erroring are not the same thing to tell a founder, and
  conflating them reads a slow boot as a broken build.

  Surface: the preview page.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An app still coming up is not reported as broken", criterion: 1114 do
    scenario "An app still coming up is not reported as broken" do
      given_ "the container is alive but has not answered yet", context do
        :ok = Fixtures.boot_waiting_workspace(context.scope)

        {:ok, context}
      end

      when_ "he looks at the pane", context do
        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "it says the app is still coming up", context do
        assert has_element?(context.view, "[data-test='preview-starting']"),
               "expected the pane to say the app is still coming up, got: #{context.html}"

        {:ok, context}
      end

      then_ "and not that it is broken", context do
        refute has_element?(context.view, "[data-test='preview-broken']"),
               "an app that has not answered yet was reported as erroring, which reads a " <>
                 "slow boot as a broken build"

        {:ok, context}
      end

      when_ "the app begins serving", context do
        Fixtures.put_workspace_serving(:serving)
        Fixtures.put_workspace_healthy(true)

        {:ok, context}
      end

      then_ "the open preview changes over without a reload", context do
        eventually(fn ->
          assert has_element?(context.view, "[data-test='preview-frame']")
          refute has_element?(context.view, "[data-test='preview-starting']")
        end)

        {:ok, context}
      end
    end
  end
end
