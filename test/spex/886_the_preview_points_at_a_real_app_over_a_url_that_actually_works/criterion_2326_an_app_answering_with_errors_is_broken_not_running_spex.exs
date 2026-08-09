defmodule CodeMySpecSpex.Story886.Criterion2326Spex do
  @moduledoc """
  Story 886 — The preview points at a real app, over a URL that actually works.
  Criterion 2326 — An app answering with errors is broken, not running.

  Rule: the pane reports the app's real state, including the phases we control
  like starting and deploying.

  A container that is up and raising on every request is running by the
  proxy's reckoning and broken by Sam's. Those are the two failures a preview
  most needs to tell apart: one is ours — the box, the boot, the deploy — and
  the other is the app he just had built, which is a codegen signal rather
  than an infrastructure problem.

  Readiness used to be "did anything answer", deliberately. During story 990
  that replaced a TCP connect, because Docker publishes the host port before
  the app serves and a connect succeeded while nothing was listening. It fixed
  "it says running before it is" and left "it says running while it is
  broken", because any HTTP response counted — 500 included.

  Surface: the workspace page, which is where a visitor is told what their
  app is doing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpecTest.FakeWorkspaceRunner

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces, runner: FakeWorkspaceRunner)
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Workspaces) end)

    start_supervised!({FakeWorkspaceRunner, healthy?: true, serving: :serving})
    :ok
  end

  spex "A running container and a working app are not the same claim" do
    scenario "An app answering with errors is broken, not running" do
      given_ "a visitor whose workspace has come up and is serving", context do
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

        {:ok, _view, html} = live(conn, ~p"/build/workspace")

        assert html =~ "It&#39;s running.",
               "a serving app should say so before we break it"

        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "the app starts raising on every request", context do
        FakeWorkspaceRunner.put_serving(:erroring)

        {:ok, _view, html} = live(context.conn, ~p"/build/workspace")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the visitor is told the app is erroring, not that it is running", context do
        refute context.html =~ "It&#39;s running.",
               "an app answering 500 must not be reported as running — that is the " <>
                 "distinction the pane exists to draw"

        assert context.html =~ "the app is erroring",
               "expected the visitor to be told their app is broken, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
