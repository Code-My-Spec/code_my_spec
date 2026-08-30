defmodule CodeMySpecSpex.Story689.Criterion5981Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 5981 — The agent's MCP tool list does not expose
  `embed_hexdocs`.

  Covers Rule "Agents have no manual hex doc embedding action —
  projection and embedding are implicit in sync, and the standalone
  `embed_hexdocs` MCP tool is removed."

  ## Observation surface

  Same approach as story 688's `embed_docs` removal scenario:
  enumerate `LocalServer.__components__(:tool)` and assert
  `embed_hexdocs` is not registered. The check via
  `__components__/1` is exactly what the MCP transport reports to
  the agent, so this is the agent surface.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.ScriptableTools

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent cannot invoke a manual embed_hexdocs action against the local MCP server" do
    scenario "embed_hexdocs is absent from the registered tool list" do
      given_ "an agent connected to the local MCP server", context do
        # given: already true — there is nothing to connect to. The local MCP
        # server is the `LocalServer` module, and its tool list is a static
        # registration read by `__components__/1`; being able to enumerate it
        # is what "connected" means here.
        # Connection is implicit in being able to enumerate the
        # registered tool components on the LocalServer module.
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

      then_ "embed_hexdocs is not present in the returned tool list", context do
        refute "embed_hexdocs" in context.tool_names,
               "Expected embed_hexdocs to be removed from LocalServer's tool registration. Tools: #{inspect(context.tool_names)}"

        # Anchor: the related search/read/list tools are still present
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
