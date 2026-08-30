defmodule CodeMySpecSpex.Story688.Criterion5973Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search
  Criterion 5973 — The agent's MCP tool list does not expose `embed_docs`.

  Covers Rule "Agents have no manual embedding action for project
  docs — embedding is implicit in file sync, and the standalone
  `embed_docs` MCP tool is removed."

  ## Observation surface

  Anubis registers MCP tools statically on the server module via
  `component/1` calls. Story 971 split that registration in two:
  `LocalServer.__components__(:tool)` is the spine an agent gets at
  connect, and `ScriptableTools.__components__(:tool)` is everything
  else, reachable only through `run_script` (see
  `LocalServer.moved?/1`). Neither list alone is "what the agent can
  invoke" any more — the union of both is. This spec reads that union.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.ScriptableTools

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent cannot invoke a manual embed_docs action against the local MCP server" do
    scenario "embed_docs is absent from the registered tool list" do
      given_ "an agent connected to the local MCP server", context do
        # given: already true — there is nothing to connect to. The local MCP
        # server is the `LocalServer` module, and its tool list is a static
        # registration read by `__components__/1`; being able to enumerate it
        # is what "connected" means here.
        {:ok, context}
      end

      when_ "the agent enumerates available tools", context do
        # Both surfaces. Since story 971 `LocalServer` advertises only the
        # spine and everything else is registered on `ScriptableTools` and
        # reached with `run_script`. The anchor below is about the knowledge
        # tools still being reachable, which is the union, not one list.
        tool_names =
          (LocalServer.__components__(:tool) ++ ScriptableTools.__components__(:tool))
          |> Enum.map(& &1.name)

        {:ok, Map.put(context, :tool_names, tool_names)}
      end

      then_ "embed_docs is not present in the returned tool list", context do
        refute "embed_docs" in context.tool_names,
               "Expected embed_docs to be removed from LocalServer's tool registration. Tools: #{inspect(context.tool_names)}"

        # Anchor: the related search/read/list tools are still there,
        # so absence is a real removal, not the whole knowledge surface
        # being missing.
        assert "semantic_search" in context.tool_names
        assert "list_knowledge" in context.tool_names
        assert "read_knowledge" in context.tool_names

        {:ok, context}
      end
    end
  end
end
