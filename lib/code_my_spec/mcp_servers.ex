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
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.Agents,
      CodeMySpec.AgentTasks,
      CodeMySpec.Analysis,
      CodeMySpec.Architecture,
      CodeMySpec.Auth,
      CodeMySpec.BddRules,
      CodeMySpec.BootVersion,
      CodeMySpec.CodeMode,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Conversations,
      CodeMySpec.Embeddings,
      CodeMySpec.Environments,
      CodeMySpec.EpicDispatch,
      CodeMySpec.Epics,
      CodeMySpec.Files,
      CodeMySpec.Generators,
      CodeMySpec.Google,
      CodeMySpec.Issues,
      CodeMySpec.Knowledge,
      CodeMySpec.Notifications,
      CodeMySpec.Paths,
      CodeMySpec.Permissions,
      CodeMySpec.Personas,
      CodeMySpec.Problems,
      CodeMySpec.Projects,
      CodeMySpec.Promotion,
      CodeMySpec.Provisioning,
      CodeMySpec.PublicUrl,
      CodeMySpec.Qa,
      CodeMySpec.Questions,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Research,
      CodeMySpec.Resources,
      CodeMySpec.ScreenState,
      CodeMySpec.Servers,
      CodeMySpec.Sessions,
      CodeMySpec.Stories,
      CodeMySpec.Tags,
      CodeMySpec.TaskOwner,
      CodeMySpec.Users,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ],
    exports: :all
end
