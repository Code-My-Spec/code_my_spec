defmodule CodeMySpecSpex.Story990.Criterion8217Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8217 — The workspace comes up and the app is running in it.

  Rule: the workspace comes up and the visitor sees the running application.

  The instance itself is a container on a Docker daemon — an external system,
  so it is swapped here the way the DNS resolver and the issues client are:
  the criterion is about what the visitor is shown when it comes up, not about
  Docker's ability to start a container.

  Surface: the `/build` LiveView through the gate, then `/build/workspace`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpecTest.FakeWorkspaceRunner

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: FakeWorkspaceRunner,
      boot_timeout: 5_000,
      poll_interval: 20
    )

    start_supervised!({FakeWorkspaceRunner, healthy?: true})

    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Workspaces) end)

    :ok
  end

  spex "The workspace comes up and the visitor sees the running application" do
    scenario "The workspace comes up and the app is running in it" do
      given_ "a visitor who has confirmed a plan", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        view
        |> answer_shaping_questions()

        view
        |> form("form[phx-submit=confirm_names]", %{
          plan: %{account_name: "Acme", project_name: "Widget Tracker"}
        })
        |> render_submit()

        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "the workspace finishes coming up", context do
        {:ok, view, _html} = live(context.conn, "/build/workspace")

        {:ok, Map.merge(context, %{view: view, html: await(view, "It&#39;s running.")})}
      end

      then_ "they are shown their application running", context do
        assert context.html =~ "It&#39;s running.",
               "expected the workspace to report itself running, got: #{context.html}"

        {:ok, context}
      end

      then_ "they are given somewhere to look at it", context do
        assert context.html =~ "Open your application"
        assert context.html =~ "http://localhost:"

        {:ok, context}
      end
    end
  end

  # The boot watcher reports by broadcast, so the screen settles a beat after
  # mount rather than during it.
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
