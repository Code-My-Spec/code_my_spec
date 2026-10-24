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
      CodeMySpec.AgentPerformance,
      CodeMySpec.Agents.Agent,
      CodeMySpec.PromotionQueue,
      CodeMySpec.Provisioning.EnvironmentRepository,
      CodeMySpec.Stories,
      CodeMySpec.ToolLibrary,
      CodeMySpec.Tools,
      CodeMySpec.Activity,
      CodeMySpec.Agents,
      CodeMySpec.Agents.RoleProfile,
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
      CodeMySpec.ExecutionContexts,
      CodeMySpec.EpicDispatch,
      CodeMySpec.Epics,
      CodeMySpec.Files,
      CodeMySpec.Generators,
      CodeMySpec.Google,
      CodeMySpec.Issues,
      CodeMySpec.Notifications,
      CodeMySpec.Observability,
      CodeMySpec.Paths,
      CodeMySpec.Permissions,
      CodeMySpec.Personas,
      CodeMySpec.Problems,
      CodeMySpec.Projects,
      CodeMySpec.Promotion,
      CodeMySpec.Provisioning,
      CodeMySpec.ProvisioningPlan,
      CodeMySpec.PublicUrl,
      CodeMySpec.Qa,
      CodeMySpec.Questions,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Research,
      CodeMySpec.Resources,
      CodeMySpec.ScreenState,
      CodeMySpec.Servers,
      CodeMySpec.Staffing,
      CodeMySpec.Tags,
      CodeMySpec.TaskOwner,
      CodeMySpec.Telemetry,
      CodeMySpec.Users,
      CodeMySpec.Users.Scope,
      CodeMySpec.LocalScope,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies,
      # `share_copy_app`/`unshare_copy_app` call `PreviewTunnel.ensure/1` and
      # `.release/1` directly, the same reasoning as every other tool here
      # that calls its own component straight through.
      CodeMySpec.Workspaces
    ],
    exports: :all
end
