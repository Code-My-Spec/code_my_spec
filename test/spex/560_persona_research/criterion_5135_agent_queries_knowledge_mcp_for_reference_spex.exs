defmodule CodeMySpecSpex.Story560.Criterion5135Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5135 — Agent queries the knowledge MCP for reference material.
  Observable: the task prompt instructs the agent to load playbook files via
  the knowledge MCP server's read_knowledge tool.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent consults embedded knowledge base" do
    scenario "prompt names read_knowledge and the playbook files" do
      given_ :persona_research_prompt

      then_ "the prompt instructs the agent to use read_knowledge on playbook files", context do
        assert context.prompt =~ "read_knowledge",
               "expected prompt to name the read_knowledge MCP tool"

        assert context.prompt =~ "persona_research/overview.md"
        assert context.prompt =~ "persona_research/pm_intake.md"
        assert context.prompt =~ "persona_research/primary_research.md"

        :ok
      end
    end
  end
end
