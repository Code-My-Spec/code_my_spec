defmodule CodeMySpecSpex.Story886.Criterion2329Spex do
  @moduledoc """
  Story 886 — The preview points at a real app, over a URL that actually works.
  Criterion 2329 — A crash in the preview becomes a signal, not a blank frame.

  Rule: errors from inside the preview reach the agent that generated the app.

  The failure this rules out is the quiet one. A framed app that throws while
  rendering shows Sam a blank rectangle, and a blank rectangle is
  indistinguishable from an app that has not finished, or one that renders
  nothing on purpose. He has no way to tell us what went wrong because he never
  saw it.

  The bridge already captured these — QA confirmed a real generated app posting
  `{source: "cms-preview", type: "error"}` to the pane. What was missing was
  anything listening, so every crash went into a void. This asserts the
  receiving half.

  Two things happen and only one is visible here. Sam is told, which is the
  "not a blank frame" part and what this spec drives. The crash is also
  recorded through `Events`, so it outlives the socket — 886 asks for a failed
  render to become something the agent can act on, and a message that dies with
  the page is not that. That half is deliberately not asserted from a `then_`,
  which observes surfaces rather than tables.

  Surface: the preview page, driven through the hook the browser pushes from.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A crash inside the preview reaches the person watching it" do
    scenario "A crash in the preview becomes a signal, not a blank frame" do
      given_ "Sam is watching his running app in the pane", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running)

        {:ok, view, _html} = live(context.conn, "/build/preview")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the app throws while rendering", context do
        html =
          render_hook(context.view, "preview_bridge", %{
            "type" => "error",
            "payload" => %{
              "message" => "Uncaught TypeError: cannot read properties of null",
              "source" => "app.js",
              "line" => 42
            }
          })

        {:ok, Map.put(context, :html, html)}
      end

      then_ "Sam is told what went wrong rather than left with an empty frame", context do
        assert context.html =~ "preview-crash",
               "the crash was swallowed — Sam is looking at a blank frame with no " <>
                 "explanation, which is the failure this criterion exists to prevent"

        assert context.html =~ "cannot read properties of null",
               "the pane reported a crash without saying what it was, got: #{context.html}"

        {:ok, context}
      end

      then_ "and the app is still framed, so he can retry rather than start over", context do
        assert context.html =~ "data-test=\"preview-frame\"",
               "the pane tore down the preview on the first error; a crash is a thing " <>
                 "to report, not a reason to stop showing the app"

        {:ok, context}
      end
    end
  end
end
