defmodule CodeMySpecSpex.Story990.Criterion8219Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8219 — The interview fills the wait instead of the visitor watching a bar.

  Rule: the story interview starts on its own while the workspace is still
  coming up.

  Boot takes minutes, and no amount of instrumentation makes minutes feel like
  seconds. The answer is not to make the bar prettier but to give the visitor
  something worth doing while it runs — so the interview is the page and the
  boot is a strip beside it.

  Surface: `/build` through the gate, then `/build/workspace` with an instance
  that is still coming up.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpecTest.FakeWorkspaceRunner

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: FakeWorkspaceRunner,
      boot_timeout: 60_000,
      poll_interval: 20
    )

    start_supervised!({FakeWorkspaceRunner, healthy?: false, alive?: true})
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Workspaces) end)
    :ok
  end

  spex "The interview runs while the workspace is still coming up" do
    scenario "The interview fills the wait instead of the visitor watching a bar" do
      given_ "a visitor whose workspace has just started coming up", context do
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

        {:ok, workspace_view, html} = live(conn, "/build/workspace")

        {:ok, Map.merge(context, %{conn: conn, view: workspace_view, html: html})}
      end

      then_ "the interview has begun without them asking for it", context do
        assert has_element?(context.view, "form[phx-submit=answer]"),
               "expected the interview to be asking a question already"

        assert context.html =~ "question 1 of",
               "expected the interview to show where they are, got: #{context.html}"

        {:ok, context}
      end

      then_ "the boot's progress stays visible alongside it", context do
        assert context.html =~ "progress",
               "expected the boot to remain visible next to the interview"

        {:ok, context}
      end
    end
  end
end
