defmodule CodeMySpecSpex.Story560.Criterion5132Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5132 — Agent narrows its questions to the gaps when the PM supplies
  partial notes. Observable: prompt enumerates the gap coverage areas (Role,
  Goals, Pain Points, Context, Decision Drivers).
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM supplies partial notes — agent must cover the gaps" do
    scenario "prompt tells the agent to cover Role/Goals/Pain/Context/Decision Drivers" do
      given_ :persona_research_prompt

      then_ "the prompt enumerates the gap coverage areas", context do
        assert context.prompt =~ "Role"
        assert context.prompt =~ "Goals"
        assert context.prompt =~ "Pain Points"
        assert context.prompt =~ "Context"
        assert context.prompt =~ "Decision Drivers"
        {:ok, context}
      end
    end
  end
end
