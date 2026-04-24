defmodule CodeMySpecSpex.Story560.Criterion5131Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5131 — Agent opens with the intake question bank when the PM has
  no notes. Observable: the task prompt instructs the agent to open with the
  intake questions from pm_intake.md.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM starts a persona research session with no prior notes" do
    scenario "task prompt directs the agent to open with the intake question bank" do
      given_ :persona_research_prompt

      then_ "the prompt instructs the agent to open with intake questions", context do
        # Anchor: we got a real persona research prompt, not an error.
        assert context.prompt =~ "Persona Research", "expected a persona research prompt"

        assert context.prompt =~ "pm_intake.md",
               "expected prompt to name pm_intake.md as the intake reference"

        assert context.prompt =~ ~r/intake/i, "expected prompt to reference an intake step"
        assert context.prompt =~ ~r/question/i, "expected prompt to instruct asking questions"

        :ok
      end
    end
  end
end
