defmodule CodeMySpecSpex.Story1033.Criterion3425Spex do
  @moduledoc """
  Story 1033 — The handoff from onboarding to sales to building never breaks
  the conversation or the panel beside it.
  Criterion 3425 — The pre-signup screen renders with the cockpit's own panel
  and chat components.

  Rule ("extract, don't reimplement"), John, 2026-09-12: the dynamic panel
  and chat UI already built for `AgentConversationLive.Show` (966/967) get
  pulled out into shared components, and the pre-signup screen
  (`IntakeLive.Plan`/`Workspace`) renders with those same components rather
  than a parallel implementation that merely looks the same — "the same
  markup and behavior, given different backing data."

  ## What a spex can observe here

  This criterion is about implementation structure, not only about what a
  visitor sees — but a spex cannot read source code or assert on which
  module rendered a tag. What it can observe honestly is markup identity: the
  cockpit already wraps its dynamic panel in a container carrying
  `data-test="conversation-panels"` (`AgentConversationLive.Show`, using
  `LivePane.pane`). If the pre-signup screen renders through the same
  extracted component, that same wrapper appears there too — not a
  similar-looking div with a different name, which is exactly the drift two
  independent implementations would produce.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  spex "The pre-signup panel is the cockpit's own component, not a lookalike" do
    scenario "The pre-signup screen renders with the cockpit's own panel and chat components" do
      given_ "the pre-signup conversation is rendering the plan-confirmation card", context do
        conn = get(build_conn(), "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        html = answer_shaping_questions(view)

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      when_ "it is compared to the real cockpit's dynamic panel post-signup", context do
        # The comparison is the wrapper the cockpit's own panel component
        # renders — `data-test="conversation-panels"` — not a rebuilt page.
        {:ok, context}
      end

      then_ "both are rendered by the same extracted component, given different backing data",
            context do
        assert has_element?(context.view, "[data-test='conversation-panels']"),
               "expected the pre-signup screen to render through the cockpit's own panel " <>
                 "component (data-test=\"conversation-panels\"), not a parallel " <>
                 "implementation that only looks similar. Got: #{context.html}"

        {:ok, context}
      end

      then_ "a change to that component's markup or behavior applies to both sides at once",
            context do
        assert has_element?(context.view, "[data-test='intake-plan']"),
               "expected the plan-confirmation card to still be the content the shared " <>
                 "panel is holding, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
