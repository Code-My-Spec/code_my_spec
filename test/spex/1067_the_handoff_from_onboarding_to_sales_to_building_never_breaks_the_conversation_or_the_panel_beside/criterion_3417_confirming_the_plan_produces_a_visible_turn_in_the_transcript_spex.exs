defmodule CodeMySpecSpex.Story1033.Criterion3417Spex do
  @moduledoc """
  Story 1033 — The handoff from onboarding to sales to building never breaks
  the conversation or the panel beside it.
  Criterion 3417 — Confirming the plan produces a visible turn in the
  transcript.

  Rule: an action taken in the panel becomes a turn in the conversation, not
  a silent side effect the agent has to poll for.

  Today `confirm_names` writes the correction to the row and navigates the
  visitor away (to the gate or to the workspace) — it never adds anything to
  the transcript, and nothing answers back. This criterion is what "the
  panel and the conversation are one thing" requires instead: the correction
  itself becomes a visitor turn, and the agent's next line responds to what
  was actually confirmed, not to its own superseded guess.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "A correction made in the panel is a turn in the conversation, not a silent write" do
    scenario "Confirming the plan produces a visible turn in the transcript" do
      given_ "the plan-confirmation card is showing in the panel", context do
        conn = get(build_conn(), "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "the visitor edits a proposed name and confirms", context do
        html =
          context.view
          |> form("form[phx-submit=confirm_names]", %{
            plan: %{account_name: "Acme", project_name: "Salon Book"}
          })
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the transcript shows what was confirmed as a turn", context do
        assert is_binary(context.html),
               "expected the confirmation to stay in this same conversation, but the " <>
                 "view was navigated away instead: #{inspect(context.html)}"

        assert has_element?(context.view, "[data-test='intake-said'][data-from='visitor']", "Acme") ||
                 context.html =~ "Acme",
               "expected the confirmed name to appear in the transcript as something the " <>
                 "visitor said, got: #{context.html}"

        {:ok, context}
      end

      then_ "the agent's next message responds to the confirmed values, not the original guesses",
            context do
        assert has_element?(context.view, "[data-test='intake-said'][data-from='agent']", "Acme") ||
                 has_element?(context.view, "[data-test='intake-said'][data-from='agent']", "Salon Book"),
               "expected the agent to respond to what was actually confirmed rather than " <>
                 "leaving its last message referring to the superseded guess, got: " <>
                 "#{context.html}"

        {:ok, context}
      end
    end
  end
end
