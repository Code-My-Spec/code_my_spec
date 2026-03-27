defmodule CodeMySpec.McpServers.LocalServer do
  @moduledoc """
  Single MCP server for the local development environment.

  Exposes tools relevant to the local agent workflow.
  Story CRUD lives on the web server — only linking is local.
  """

  use Anubis.Server,
    name: "codemyspec-local",
    version: "1.0.0",
    capabilities: [:tools]

  # Scope resolved from x-working-dir header via merge_transport_assigns.

  # Bootstrap — init, setup, resource installation
  component(CodeMySpec.McpServers.Bootstrap.Tools.GetInitStatus)
  component(CodeMySpec.McpServers.Bootstrap.Tools.GetSetupStatus)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InitProject)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallAppResources)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallAgentsMd)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallRules)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallCredoChecks)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallClaudeMd)

  # Stories — delegates to remote server API
  component(CodeMySpec.McpServers.Stories.Tools.ListStories)
  component(CodeMySpec.McpServers.Stories.Tools.ListStoryTitles)
  component(CodeMySpec.McpServers.Stories.Tools.SetStoryComponent)
  component(CodeMySpec.McpServers.Stories.Tools.AnalyzeStoryLinkage)

  # Architecture
  component(CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraph)
  component(CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories)

  # Requirements — read-only discovery
  component(CodeMySpec.McpServers.Requirements.Tools.ListRequirements)
  component(CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement)

  # Tasks — start → evaluate lifecycle
  component(CodeMySpec.McpServers.Tasks.Tools.StartTask)
  component(CodeMySpec.McpServers.Tasks.Tools.EvaluateTask)

  # Issues — full lifecycle
  component(CodeMySpec.McpServers.Issues.Tools.CreateIssue)
  component(CodeMySpec.McpServers.Issues.Tools.ListIssues)
  component(CodeMySpec.McpServers.Issues.Tools.GetIssue)
  component(CodeMySpec.McpServers.Issues.Tools.AcceptIssue)
  component(CodeMySpec.McpServers.Issues.Tools.DismissIssue)
  component(CodeMySpec.McpServers.Issues.Tools.ResolveIssue)
end
