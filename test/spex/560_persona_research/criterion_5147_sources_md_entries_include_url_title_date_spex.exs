defmodule CodeMySpecSpex.Story560.Criterion5147Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5147 — sources.md entries include URL, title, and access date.
  Observable: the task prompt instructs the agent to write each sources.md
  entry with URL + title + access date.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "prompt specifies sources.md entry format" do
    scenario "prompt lists URL, title, and access date as required fields" do
      given_ :persona_research_prompt

      then_ "the prompt enumerates URL + title + access date", context do
        assert context.prompt =~ ~r/URL/
        assert context.prompt =~ ~r/title/i
        assert context.prompt =~ ~r/access date|accessed/i

        :ok
      end
    end
  end
end
