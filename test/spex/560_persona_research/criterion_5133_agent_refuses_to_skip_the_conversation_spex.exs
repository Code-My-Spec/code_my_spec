defmodule CodeMySpecSpex.Story560.Criterion5133Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5133 — Agent refuses to skip the conversation. Observable: prompt
  forbids starting to write before the intake produces signal and instructs
  challenging thin input.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM asks the agent to skip questions and just write" do
    scenario "prompt forbids bypassing the intake and directs challenging thin input" do
      given_ :persona_research_prompt

      then_ "the prompt forbids skipping and requires challenging thin input", context do
        assert context.prompt =~ ~r/do not start writing/i,
               "expected prompt to forbid skipping the intake"

        assert context.prompt =~ ~r/challenge/i,
               "expected prompt to instruct challenging thin input"

        :ok
      end
    end
  end
end
