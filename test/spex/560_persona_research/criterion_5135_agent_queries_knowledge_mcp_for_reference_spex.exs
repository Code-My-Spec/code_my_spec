defmodule CodeMySpecSpex.Story560.Criterion5135Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5135 — Agent queries the knowledge MCP for reference material.
  Observable: the task prompt instructs the agent to load playbook files via
  the knowledge MCP server's read_knowledge tool.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent consults embedded knowledge base" do
    scenario "prompt names read_knowledge and the playbook files" do
      given_ :persona_research_prompt

      then_ "the prompt instructs the agent to load playbook files", context do
        assert context.prompt =~ "persona_research/workflow.md",
               "expected prompt to point at the persona_research workflow playbook"

        for file <- ~w(overview.md pm_intake.md primary_research.md) do
          assert context.prompt =~ file,
                 "expected prompt to reference topic file #{file}"
        end

        {:ok, context}
      end
    end
  end
end
