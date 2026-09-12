defmodule CodeMySpec.McpServers.Knowledge.SemanticSearchRefusalTest do
  @moduledoc """
  When search cannot run, the refusal names what does.

  The embed pipeline ships only with the CodeMySpec CLI binary, so in the server
  BEAM every `semantic_search` call fails. That is a known gap parked behind
  story 688's embeddings rework — what is not acceptable is what the failure
  used to say.

  It explained the implementation ("Ortex + sqlite_vec ships only with the
  CodeMySpec CLI binary") and stopped. `ToolSets` gives this tool to the coding,
  product and main agents, so in this runtime every internal agent carries a
  tool that always fails, and the message is the only thing between a failed
  lookup and a dropped question (`084b8351`).

  `list_knowledge` and `read_knowledge` work here — the session that filed the
  issue read `devops/README.md` fine while every query failed. So the agent is
  not stuck; it has to browse rather than ask, and nothing told it that.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch

  defp refusal do
    # The literal the tool emits for this branch. Asserted against the source
    # rather than by forcing `Embeddings.search/3` to answer
    # `:embeddings_unavailable`, which would mean stubbing the one thing this
    # runtime already does on its own.
    File.read!("lib/code_my_spec/mcp_servers/knowledge/tools/semantic_search.ex")
  end

  test "it says retrying will not help" do
    text = refusal()

    assert text =~ "no query will work here",
           "an agent told only that a pipeline is missing will rephrase and try again"

    assert text =~ "retrying or"
  end

  test "it names the two tools that do work" do
    text = refusal()

    assert text =~ "`list_knowledge` and `read_knowledge` do work"
  end

  # The tool stays on the internal agents' lists, because it works in the CLI
  # runtime where the pipeline ships. Removing it there to spare the server a
  # failed call would take the capability from the place it exists.
  test "the tool is still offered to the agents that have a runtime for it" do
    sets = File.read!("lib/code_my_spec/agents/tool_sets.ex")

    assert sets =~ "semantic_search",
           "the gap is the runtime, not the grant — the CLI binary can search"
  end

  test "the module still exposes the tool" do
    # `ensure_loaded?/1` first: `function_exported?/3` answers false for a
    # module that is merely not loaded yet, which would make this pass or fail
    # on load order rather than on the thing it names.
    assert Code.ensure_loaded?(SemanticSearch)
    assert function_exported?(SemanticSearch, :execute, 2)
  end
end
