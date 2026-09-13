defmodule CodeMySpecSpex.Story990.Criterion2974Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 2974 — What the visitor first typed is still there at the end.

  Rule: one conversation, start to finish — not three pages that each replace
  the one before.

  It used to be three steps, each a full-page heading that overwrote the
  last: describe, then "Tell me a bit more", then "Here's what I think
  you're building". A visitor who had just typed a paragraph landed on a
  fresh page that read as starting over. `IntakeLive.Plan`'s own moduledoc
  names this as the bug the single-conversation design replaced.

  So the claim here is literal: the visitor's own first sentence is still on
  screen once their project exists, in the same conversation, not a fact
  recorded somewhere and re-summarised.
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

  spex "The conversation carries forward rather than being replaced" do
    scenario "What the visitor first typed is still there at the end" do
      given_ "a visitor who has described what they want to build", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, @description)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "they answer the questions, confirm the plan, and their project comes up",
            context do
        answer_shaping_questions(context.view)

        to = confirm_plan(context.view, %{location: "cloud"})

        assert to == "/build/workspace",
               "expected confirming the plan to move the visitor on to their workspace, " <>
                 "got: #{inspect(to)}"

        {:ok, workspace_view, html} = live(context.conn, to)

        {:ok, context |> Map.put(:view, workspace_view) |> Map.put(:html, html)}
      end

      then_ "everything they said is still on the screen, in the order they said it",
            context do
        assert context.html =~ @description,
               "expected the visitor's own first sentence still on screen once their " <>
                 "project exists, got: #{context.html}"

        described_at = :binary.match(context.html, @description) |> elem(0)

        assert context.html =~ "What do you want to build?",
               "expected the opening question to still be part of the same transcript, " <>
                 "got: #{context.html}"

        opening_at = :binary.match(context.html, "What do you want to build?") |> elem(0)

        assert opening_at < described_at,
               "expected the conversation in the order it was said — the opening question " <>
                 "before the visitor's own answer to it"

        {:ok, context}
      end

      then_ "they were never taken to a page that started over", context do
        refute context.html =~ "Tell me a bit more",
               "expected no separate page reintroducing the conversation, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
