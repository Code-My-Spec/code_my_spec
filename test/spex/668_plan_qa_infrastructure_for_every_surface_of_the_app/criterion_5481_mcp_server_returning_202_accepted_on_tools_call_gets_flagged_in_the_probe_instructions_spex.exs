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

      then_ "the probe section calls out the 202 Accepted MCP transport quirk", context do
        prompt = context.prompt

        assert prompt =~ "202",
               "expected prompt to mention 202 Accepted MCP behavior, got: #{prompt}"

        assert prompt =~ ~r/curl/i,
               "expected prompt to mention curl in the MCP context, got: #{prompt}"

        assert prompt =~ ~r/MCP|tools\/call|initialize/i,
               "expected prompt to mention the MCP transport, got: #{prompt}"

        {:ok, context}
      end
    end
  end
end
