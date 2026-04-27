defmodule CodeMySpecSpex.Story560.Criterion5138Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5138 — Agent pushes back on a one-line persona description.
  Observable: the task prompt instructs the agent to challenge thin input
  with targeted follow-up questions.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM provides a one-line persona description" do
    scenario "prompt directs the agent to challenge thin input" do
      given_ :persona_research_prompt

      then_ "the prompt calls out thin input and directs follow-up questions", context do
        assert context.prompt =~ ~r/thin/i,
               "expected prompt to name 'thin' input as a failure mode"

        assert context.prompt =~ ~r/follow-up|push back|challenge/i,
               "expected prompt to direct challenging thin input"

        {:ok, context}
      end
    end
  end
end
