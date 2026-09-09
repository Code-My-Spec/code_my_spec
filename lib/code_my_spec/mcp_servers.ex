defmodule CodeMySpec.McpServers do
  @moduledoc """
  MCP (Model Context Protocol) servers context.

  This context provides the namespace for MCP server implementations.
  The actual MCP protocol handling is delegated to Anubis.Server.

  Declared as its own Boundary so other top-level boundaries
  (`CodeMySpecSpex`, `CodeMySpecWeb`, etc.) can depend on the agent
  surface without pulling in all of `CodeMySpec`. Spex specs in
  particular call MCP tool modules directly because that's the agent's
  surface — the same code path the agent harness invokes.
  """
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec,
      CodeMySpec.Auth,
      CodeMySpec.BootVersion,
      CodeMySpec.CodeMode,
      CodeMySpec.Embeddings,
      CodeMySpec.Environments,
      CodeMySpec.Google,
      CodeMySpec.Knowledge,
      CodeMySpec.Paths,
      CodeMySpec.Projects,
      CodeMySpec.PublicUrl,
      CodeMySpec.Repo,
      CodeMySpec.Research,
      CodeMySpec.ScreenState,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all
end
