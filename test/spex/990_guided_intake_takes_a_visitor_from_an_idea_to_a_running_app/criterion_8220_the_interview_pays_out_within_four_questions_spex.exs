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

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Intake.Interview
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

  spex "The interview shows its derived rules within four questions" do
    scenario "The interview pays out within four questions" do
      given_ "a visitor in the interview", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

        view
        |> form("form[phx-submit=answer]", %{
          plan: %{needs_sign_in: "true", separate_copies: "true", who_uses: "salon owners"}
        })
        |> render_submit()

        view
        |> form("form[phx-submit=confirm_names]", %{
          plan: %{account_name: "Acme", project_name: "Widget Tracker"}
        })
        |> render_submit()

        {:ok, workspace_view, _html} = live(conn, "/build/workspace")

        {:ok, Map.merge(context, %{conn: conn, view: workspace_view})}
      end

      when_ "they keep answering until it stops asking", context do
        html = answer_until_done(context.view, Interview.question_cap() + 1, 0)

        {:ok, Map.merge(context, %{html: elem(html, 0), asked: elem(html, 1)})}
      end

      then_ "they were asked no more than four questions", context do
        assert context.asked <= Interview.question_cap(),
               "expected at most #{Interview.question_cap()} questions, was asked #{context.asked}"

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
    case has_element?(view, "form[phx-submit=answer]") do
      false ->
        {render(view), asked}

      true ->
        html =
          view
          |> form("form[phx-submit=answer]", %{answer: "whatever they typed"})
          |> render_submit()

        case has_element?(view, "form[phx-submit=answer]") do
          false -> {html, asked + 1}
          true -> answer_until_done(view, remaining - 1, asked + 1)
        end
    end
  end
end
