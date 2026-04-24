defmodule CodeMySpecSpex.Story560.Criterion5137Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5137 — Agent reports a research dead-end instead of inventing
  content. Observable: the task prompt instructs the agent to ask the PM for
  source leads rather than fabricate.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "research produces no useful data" do
    scenario "prompt forbids inventing content and directs asking PM for leads" do
      given_ :persona_research_prompt

      then_ "the prompt forbids fabrication and directs asking PM for source leads", context do
        assert context.prompt =~ ~r/do not invent|not invent|invent content/i,
               "expected prompt to forbid inventing content"

        assert context.prompt =~ ~r/source leads|ask the PM/i,
               "expected prompt to direct asking the PM for source leads"

        :ok
      end
    end
  end
end
