defmodule CodeMySpecSpex.Story560.Criterion5134Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5134 — Agent runs a web search once PM input is sufficient.
  Observable: the task prompt instructs the agent to use web search as a
  primary research source after the intake.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "intake produces signal — agent proceeds to research" do
    scenario "prompt names web search as a primary source" do
      given_ :persona_research_prompt

      then_ "the prompt instructs the agent to use web search", context do
        assert context.prompt =~ ~r/web search/i,
               "expected prompt to instruct web search"

        assert context.prompt =~ ~r/research/i,
               "expected prompt to reference the research phase"

        {:ok, context}
      end
    end
  end
end
