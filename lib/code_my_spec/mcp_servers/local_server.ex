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

  # Bootstrap — project linking, resource installation
  component(CodeMySpec.McpServers.Bootstrap.Tools.ListProjects)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InitProject)
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

  # Requirements — discovery and sync
  component(CodeMySpec.McpServers.Requirements.Tools.ListRequirements)
  component(CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement)
  component(CodeMySpec.McpServers.Requirements.Tools.SyncProject)

  # Tasks — start → evaluate lifecycle
  component(CodeMySpec.McpServers.Tasks.Tools.StartTask)
  component(CodeMySpec.McpServers.Tasks.Tools.AssignTask)
  component(CodeMySpec.McpServers.Tasks.Tools.EvaluateTask)
  component(CodeMySpec.McpServers.Tasks.Tools.ListTasks)

  # Hexdocs — embed and search hex dependency docs
  component(CodeMySpec.McpServers.Hexdocs.Tools.EmbedHexdocs)
  component(CodeMySpec.McpServers.Hexdocs.Tools.SearchHexdocs)

  # Knowledge — browse, read, search, and embed project docs
  component(CodeMySpec.McpServers.Knowledge.Tools.EmbedDocs)
  component(CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge)
  component(CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge)
  component(CodeMySpec.McpServers.Knowledge.Tools.SearchKnowledge)
  component(CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch)

  # Issues — full lifecycle
  component(CodeMySpec.McpServers.Issues.Tools.CreateIssue)
  component(CodeMySpec.McpServers.Issues.Tools.ListIssues)
  component(CodeMySpec.McpServers.Issues.Tools.GetIssue)
  component(CodeMySpec.McpServers.Issues.Tools.AcceptIssue)
  component(CodeMySpec.McpServers.Issues.Tools.DismissIssue)
  component(CodeMySpec.McpServers.Issues.Tools.ResolveIssue)
end
