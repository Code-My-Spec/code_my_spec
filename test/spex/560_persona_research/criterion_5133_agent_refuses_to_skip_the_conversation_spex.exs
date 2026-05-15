defmodule CodeMySpecSpex.Story560.Criterion5133Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5133 — Agent refuses to skip the conversation. Observable: prompt
  forbids starting to write before the intake produces signal and instructs
  challenging thin input.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM asks the agent to skip questions and just write" do
    scenario "prompt forbids bypassing the intake and directs challenging thin input" do
      given_ :persona_research_prompt

      then_ "the prompt forbids skipping and requires challenging thin input", context do
        assert context.prompt =~ ~r/challenge/i,
               "expected prompt to instruct challenging thin input"

        assert context.prompt =~ "priv/knowledge/persona_research/workflow.md",
               "expected prompt to point at the persona_research workflow playbook (details of the no-skip rule live there)"

        {:ok, context}
      end
    end
  end
end
