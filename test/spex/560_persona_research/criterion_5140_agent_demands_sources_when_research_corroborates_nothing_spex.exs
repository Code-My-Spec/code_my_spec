defmodule CodeMySpecSpex.Story560.Criterion5140Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5140 — Agent demands sources when research corroborates nothing.
  Observable: the task prompt tells the agent to require source leads from
  the PM before writing if research returns nothing.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "research produces no supporting evidence" do
    scenario "prompt directs the agent to demand sources from the PM" do
      given_ :persona_research_prompt

      then_ "the prompt requires asking the PM for sources when research fails", context do
        assert context.prompt =~ ~r/source leads|ask the PM for source/i,
               "expected prompt to instruct asking the PM for source leads"

        assert context.prompt =~ ~r/triangulate|three|≥3/i,
               "expected prompt to reference the triangulation guardrail"

        {:ok, context}
      end
    end
  end
end
