defmodule CodeMySpecSpex.Story560.Criterion5139Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5139 — Agent ends the session rather than produce a thin persona.
  Observable: the task prompt instructs the agent to end the session without
  writing if the evidence bar is not met.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM refuses to provide more context after follow-ups" do
    scenario "prompt directs the agent to end the session without writing" do
      given_ :persona_research_prompt

      then_ "the prompt directs ending the session rather than producing a thin persona",
            context do
        assert context.prompt =~ ~r/thin in|fabricate/i,
               "expected prompt to flag fabrication / thin-in nothing-out"

        assert context.prompt =~ "persona_research/workflow.md",
               "expected prompt to point at the persona_research workflow playbook (end-session-on-thin-evidence rule lives there)"

        {:ok, context}
      end
    end
  end
end
