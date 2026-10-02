defmodule CodeMySpec.McpServers.Knowledge.SemanticSearchRefusalTest do
  @moduledoc """
  When search cannot run, the refusal names what does.

  A runtime with no embeddings backend configured fails every `semantic_search`
  call. The failure used to explain the implementation and stop. `ToolSets`
  gives this tool to the coding, product and main agents, so there every
  internal agent carries a tool that always fails, and the message is the only
  thing between a failed lookup and a dropped question (`084b8351`).

  `list_knowledge` and `read_knowledge` work here — the session that filed the
  issue read `devops/README.md` fine while every query failed. So the agent is
  not stuck; it has to browse rather than ask, and nothing told it that.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile
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

  # The tool stays on the internal agents' lists, because it works wherever a
  # backend is configured. Removing it to spare an unconfigured runtime a failed
  # call would take the capability from the places it exists.
  test "the tool is still offered to the agents that have a runtime for it" do
    granted? =
      Enum.any?(RoleProfile.roles(), &RoleProfile.carries?(&1, "semantic_search"))

    assert granted?,
           "the gap is the runtime, not the grant"
  end

  test "the module still exposes the tool" do
    # `ensure_loaded?/1` first: `function_exported?/3` answers false for a
    # module that is merely not loaded yet, which would make this pass or fail
    # on load order rather than on the thing it names.
    assert Code.ensure_loaded?(SemanticSearch)
    assert function_exported?(SemanticSearch, :execute, 2)
  end
end
