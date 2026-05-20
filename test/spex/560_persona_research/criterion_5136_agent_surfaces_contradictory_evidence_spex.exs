defmodule CodeMySpecSpex.Story560.Criterion5136Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5136 — Agent surfaces contradictory evidence to the PM. Observable:
  the task prompt instructs the agent to present conflicts back to the PM
  rather than silently picking a side.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "sources disagree on a persona claim" do
    scenario "prompt instructs surfacing the conflict to the PM" do
      given_ :persona_research_prompt

      then_ "the prompt tells the agent to surface conflicts", context do
        assert context.prompt =~ "persona_research/workflow.md",
               "expected prompt to point at the persona_research workflow playbook (conflict-handling rule lives there)"

        {:ok, context}
      end
    end
  end
end
