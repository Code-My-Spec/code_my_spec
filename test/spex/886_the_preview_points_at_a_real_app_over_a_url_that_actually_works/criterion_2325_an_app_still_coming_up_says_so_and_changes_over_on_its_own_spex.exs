defmodule CodeMySpecSpex.Story886.Criterion2325Spex do
  @moduledoc """
  Story 886 — The preview points at a real app, over a URL that actually works.
  Criterion 2325 — An app still coming up says so, and changes over on its own.

  Rule: the pane reports the app's real state, including the phases we control
  like starting and deploying.

  Two claims, and the second is the one that is easy to skip. Saying "still
  starting" is straightforward. Changing over by itself, on the page the
  visitor already has open, is the part that decides whether the pane is
  trustworthy: a visitor who has to reload to find out is a visitor who will
  reload during the boot, see a spinner, and conclude it hung.

  The state is asked rather than guessed from whether the proxy got an answer,
  which is what makes "starting" distinguishable from "crashed" at all — both
  fail to answer. That distinction is the reason this story does not stop at
  the self-contained component in story 1000.

  Deliberately driven from the test rather than by waiting out a real boot:
  the fake decides when the app starts answering, so the scenario observes the
  starting state on purpose instead of racing a watcher's wall clock — a race
  that is lost on a loaded machine, which is exactly where it must not flake.

  Surface: the workspace page, which is where a visitor is told what their app
  is doing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A pane that is still coming up says so, and keeps up on its own" do
    scenario "An app still coming up says so, and changes over on its own" do
      given_ "a visitor whose workspace is still starting", context do
        # Not answering yet, but the container is up: an app on its way, which
        # is the state under test.
        Fixtures.install_workspace_runner(healthy?: false, alive?: true, serving: :down)

        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        answer_shaping_questions(view)

        view
        |> form("form[phx-submit=confirm_names]", %{
          plan: %{account_name: "Acme", project_name: "Widget Tracker"}
        })
        |> render_submit()

        {:ok, workspace_view, html} = live(conn, "/build/workspace")

        {:ok, Map.merge(context, %{conn: conn, view: workspace_view, html: html})}
      end

      then_ "the page says it is still coming up rather than showing nothing", context do
        refute context.html =~ "It&#39;s running.",
               "an app that has not answered yet must not be reported as running"

        assert context.html =~ "loading loading-spinner",
               "expected the visitor to see that it is still working, got: #{context.html}"

        {:ok, context}
      end

      when_ "the app finishes starting and begins answering", context do
        Fixtures.put_workspace_serving(:serving)
        Fixtures.put_workspace_healthy(true)

        # The same page the visitor already had open. Opening a new one would
        # prove the status is readable, not that it arrives.
        {:ok, Map.put(context, :settled, await(context.view, "It&#39;s running."))}
      end

      then_ "the page he already had open changes over by itself", context do
        assert context.settled =~ "It&#39;s running.",
               "the visitor had to reload to find out his app came up"

        {:ok, context}
      end

      then_ "and it offers him the app rather than leaving him to find it", context do
        assert context.settled =~ "Open your application"

        {:ok, context}
      end
    end
  end

  spex "A pane keeps up with a container nobody is watching" do
    scenario "The pane changes over even when no watcher is announcing it" do
      given_ "Sam is watching a pane whose container has stopped answering", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running)

        # A workspace that was up and is not answering now: the row still says
        # running, the container does not respond. That is what a restarted
        # container looks like, and it is reached without a boot — so nothing
        # is watching it and no broadcast is coming.
        Fixtures.put_workspace_serving(:down)

        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the pane says it is coming up rather than framing a dead address", context do
        assert context.html =~ "preview-starting",
               "expected the pane to say the app is still coming up, got: #{context.html}"

        refute context.html =~ "preview-frame",
               "the pane framed an address nothing is serving, which renders blank " <>
                 "and reads to Sam as his app being broken"

        {:ok, context}
      end

      when_ "the container starts answering again, with nobody to announce it", context do
        Fixtures.put_workspace_serving(:serving)

        {:ok, Map.put(context, :settled, await(context.view, "preview-frame"))}
      end

      then_ "the page he already had open frames the app by itself", context do
        assert context.settled =~ "preview-frame",
               "the pane sat on \"Starting your app…\" while the app served. Broadcasts " <>
                 "only come from the watcher a boot starts, so a container that came " <>
                 "back any other way left this page wrong until Sam reloaded — and he " <>
                 "has no reason to think a reload is what he needs"

        refute context.settled =~ "preview-starting",
               "the pane framed the app and went on claiming it was still starting"

        {:ok, context}
      end
    end
  end

  # The boot watcher reports by broadcast, so the page updates a beat after the
  # fake starts answering rather than during the same call.
  defp await(view, text, attempts \\ 250)

  defp await(view, text, 0), do: flunk("never rendered #{inspect(text)}: #{render(view)}")

  defp await(view, text, attempts) do
    html = render(view)
    await_rendered(String.contains?(html, text), html, view, text, attempts)
  end

  defp await_rendered(true, html, _view, _text, _attempts), do: html

  defp await_rendered(false, _html, view, text, attempts) do
    Process.sleep(20)
    await(view, text, attempts - 1)
  end
end
