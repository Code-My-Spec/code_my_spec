defmodule CodeMySpecSpex.Story990.Criterion8220Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 8220 — The interview pays out within four questions.

  Rule: the interview shows the visitor its derived rules within four
  questions.

  A pacing rule rather than a feature. The interview lands immediately after
  an instant-gratification moment, and a quarter of an hour of typing right
  there collapses the pace it just bought. Four questions, then show them what
  they bought with the answers.

  Surface: `/build/workspace`, answering until it pays out.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  alias CodeMySpecTest.FakeWorkspaceRunner

  @endpoint CodeMySpecWeb.Endpoint

  @question_form "form[phx-submit=answer]"

  # The number the story states, not the one the code happens to hold. Asking
  # Interview.question_cap/0 would make this assertion circular — raise the cap
  # to ten and the spex would still pass.
  @cap 4

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

  spex "The interview shows its derived rules within four questions" do
    scenario "The interview pays out within four questions" do
      given_ "a visitor in the interview", context do
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

        {:ok, workspace_view, _html} = live(conn, "/build/workspace")

        {:ok, Map.merge(context, %{conn: conn, view: workspace_view})}
      end

      when_ "they keep answering until it stops asking", context do
        html = answer_until_done(context.view, @cap + 1, 0)

        {:ok, Map.merge(context, %{html: elem(html, 0), asked: elem(html, 1)})}
      end

      then_ "they were asked no more than four questions", context do
        assert context.asked <= @cap,
               "expected at most #{@cap} questions, was asked #{context.asked}"

        {:ok, context}
      end

      then_ "they are shown the rules derived from their answers", context do
        assert context.html =~ "the rules I derived",
               "expected the interview to pay out with rules, got: #{context.html}"

        {:ok, context}
      end
    end
  end

  # Answers whatever is on screen until the question form is gone, counting
  # how many it was asked. The bound guards against an interview that never
  # pays out — which is the failure this criterion exists to catch.
  defp answer_until_done(view, 0, asked), do: {render(view), asked}

  defp answer_until_done(view, remaining, asked) do
    answer_if_asked(has_element?(view, @question_form), view, remaining, asked)
  end

  defp answer_if_asked(false, view, _remaining, asked), do: {render(view), asked}

  defp answer_if_asked(true, view, remaining, asked) do
    html =
      view
      |> form(@question_form, %{answer: "whatever they typed"})
      |> render_submit()

    keep_answering(has_element?(view, @question_form), html, view, remaining, asked)
  end

  defp keep_answering(false, html, _view, _remaining, asked), do: {html, asked + 1}

  defp keep_answering(true, _html, view, remaining, asked),
    do: answer_until_done(view, remaining - 1, asked + 1)
end
