defmodule CodeMySpecSpex.Story668.Criterion5481Spex do
  @moduledoc """
  Story 668 — Plan QA infrastructure for every surface of the app
  Criterion 5481 — MCP server returning 202 Accepted on tools/call
  gets flagged in the probe instructions.

  Rule (failure path): plain one-shot curl breaks against Anubis
  Streamable HTTP MCP servers — `tools/call` returns 202 Accepted
  with the response body delivered over the original SSE init
  stream. The probe prompt warns about this case so future QA runs
  don't waste time discovering it from scratch.

  Surface: `start_task` for the `qa_setup` project requirement.
  Pure prompt-content test — no real MCP server is exercised.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA setup prompt warns about Anubis 202 Accepted MCP behavior" do
    scenario "MCP server returning 202 Accepted on tools/call gets flagged in the probe instructions" do
      given_ :qa_setup_task_started

      then_ "the prompt routes the agent to the probe playbook (which flags the 202 quirk)",
            context do
        prompt = context.prompt

        # The Anubis Streamable HTTP "202 Accepted on tools/call" quirk —
        # and the rule that plain one-shot curl can't drive MCP tool calls
        # — lives in priv/knowledge/qa_setup/workflow.md's probe section.
        # The prompt routes the agent there.
        assert prompt =~ ~r/priv\/knowledge\/qa_setup\/workflow\.md/,
               "expected the prompt to reference the qa_setup workflow playbook " <>
                 "(which covers the 202/MCP transport quirks), got: #{prompt}"

        {:ok, context}
      end
    end
  end
end
