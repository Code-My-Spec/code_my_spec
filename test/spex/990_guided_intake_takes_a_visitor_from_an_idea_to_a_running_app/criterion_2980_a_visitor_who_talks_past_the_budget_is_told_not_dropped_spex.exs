defmodule CodeMySpecSpex.Story990.Criterion2980Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 2980 — A visitor who talks past the budget is told, not dropped.

  Rule, as resolved with John (2026-09-12, this session): fold this into the
  budget the shaper already enforces (`Shaper.max_questions/0`) rather than
  invent a second, separate ten-turn counter with its own bring-your-own-
  provider offer. The distinguishing claim this criterion still makes once
  that's dropped: whatever the model would otherwise keep doing, the visitor
  is never left mid-conversation with nothing — the budget forces a plan, and
  everything they said survives into it.

  The original wording ("ten turns", "offered the way to carry on with their
  own provider") predates this fold-in and is stale — see the story's own
  2026-09-12 note that most of its 24 criteria need a fresh Three Amigos pass
  rather than a line-by-line patch. Recorded here rather than resolved by
  editing the criterion text, per that note.

  ## Why a purpose-built double, not `Shaper.Scripted`

  `Shaper.Scripted.shape/2` concludes the moment there is one turn, so it
  never actually exercises `Shaper.shape/2`'s own cap — the outer
  `when length(turns) >= max_questions, do: conclude` clause never has
  anything to override. What this criterion is actually about is that clause:
  a model that would keep asking forever does not get to. Proving that needs
  an implementation that never wants to stop, on its own — hence
  `NeverConcludes` below, in the same spirit as `Shaper.Scripted` itself: a
  swappable implementation for a scenario the deterministic default can't
  produce, not a stub of the surface under test (`Shaper.shape/2`, the
  budget-enforcing wrapper, still runs for real).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  defmodule NeverConcludes do
    @moduledoc "A shaper that always wants another question, and never gets one past the cap."
    @behaviour CodeMySpec.Intake.Shaper

    @impl true
    def shape(_plan, _turns), do: {:ask, "Tell me more about your business?"}

    @impl true
    def conclude(_plan, _turns) do
      {:ok, %{needs_sign_in: false, separate_copies: false, who_uses: "the people who run it"}}
    end
  end

  setup do
    previous = Application.get_env(:code_my_spec, CodeMySpec.Intake, [])
    Application.put_env(:code_my_spec, CodeMySpec.Intake, shaper: NeverConcludes)
    on_exit(fn -> Application.put_env(:code_my_spec, CodeMySpec.Intake, previous) end)
    :ok
  end

  spex "The shaping budget forces a plan even from a model that never wants to stop" do
    scenario "A visitor who talks past the budget is told, not dropped" do
      given_ "a visitor who keeps answering, past the point a real model would ever ask",
            context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")

        answers = List.duplicate("Just my business.", CodeMySpec.Intake.Shaper.max_questions())
        html = answer_shaping_questions(view, answers)

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "they are shown a plan rather than asked to keep going", context do
        refute has_element?(context.view, "form[phx-submit=answer]"),
               "the shaper kept asking past its own budget — nothing forced it to a plan, " <>
                 "so a model that never wants to stop would never let this visitor go. " <>
                 "Got: #{context.html}"

        assert has_element?(context.view, "[data-test='intake-plan']"),
               "expected the budget to force a plan once it ran out, got: #{context.html}"

        {:ok, context}
      end

      then_ "everything they said is still reflected in it", context do
        assert context.html =~ "a booking tool for hair salons",
               "expected the visitor's own description to survive being cut off at the " <>
                 "budget, got: #{context.html}"

        assert context.html =~ "Just my business.",
               "expected the visitor's last answer to survive being cut off at the " <>
                 "budget rather than being dropped along with the rest of the " <>
                 "conversation, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
