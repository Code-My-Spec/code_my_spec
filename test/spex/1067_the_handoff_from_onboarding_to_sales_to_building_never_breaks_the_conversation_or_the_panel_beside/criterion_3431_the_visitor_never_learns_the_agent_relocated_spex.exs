defmodule CodeMySpecSpex.Story1033.Criterion3431Spex do
  @moduledoc """
  Story 1033 — The handoff from onboarding to sales to building never breaks
  the conversation or the panel beside it.
  Criterion 3431 — The visitor never learns the agent relocated.

  Rule: the handoff is a relocation, not a swap. One `Conversations` record,
  created at the first message, is the same row the real project agent reads
  from after handoff — not a new conversation started post-signup and
  backfilled with context. From the visitor's side, nothing should announce
  a transition happened at all.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @description "a booking tool for hair salons, so owners can see their week"

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  spex "Nothing in the conversation announces the agent relocated" do
    scenario "The visitor never learns the agent relocated" do
      given_ "a visitor who completed the pre-signup conversation and signed up", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, @description)
        answer_shaping_questions(view)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "their working copy comes up and the agent starts running there instead", context do
        to = confirm_plan(context.view, %{location: "cloud"})

        assert to == "/build/workspace",
               "expected a signed-in visitor to be sent to their workspace, got #{inspect(to)}"

        {:ok, workspace_view, html} = live(context.conn, to)

        {:ok, context |> Map.put(:workspace_view, workspace_view) |> Map.put(:html, html)}
      end

      then_ "nothing in the conversation announces a handoff, a relocation, or a new agent",
            context do
        refute context.html =~ ~r/hand[\s-]?off|relocat|switching agents|new agent/i,
               "the visitor was told about a handoff or relocation, which the conversation " <>
                 "should never surface. Got: #{context.html}"

        {:ok, context}
      end

      then_ "the visitor is not asked to restate anything they already said", context do
        assert context.html =~ @description,
               "expected what the visitor already said to still be part of the " <>
                 "conversation rather than being asked again, got: #{context.html}"

        # The opening question ("What do you want to build?") is expected to
        # still be on screen too — it is history, not a re-ask. What would
        # signal a re-ask is a *second* composer prompting for the same
        # description, which the workspace page never renders: past the
        # gate, the composer is always the interview's "answer" form or none
        # at all, never "describe" again.
        refute context.html =~ ~s(phx-submit="describe"),
               "the visitor was shown the description composer again after signing up, " <>
                 "which is exactly what asking them to restate their idea would look " <>
                 "like. Got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
