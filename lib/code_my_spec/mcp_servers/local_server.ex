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

  # Hexdocs — embed hex dependency docs (search is unified via SemanticSearch)
  component(CodeMySpec.McpServers.Hexdocs.Tools.EmbedHexdocs)

  # Knowledge — browse, read, embed project docs + unified semantic search
  # across every embedded source (knowledge, project_knowledge, spec, rules,
  # hexdocs:*).
  component(CodeMySpec.McpServers.Knowledge.Tools.EmbedDocs)
  component(CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge)
  component(CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge)
  component(CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch)

  # Issues — full lifecycle
  component(CodeMySpec.McpServers.Issues.Tools.CreateIssue)
  component(CodeMySpec.McpServers.Issues.Tools.ListIssues)
  component(CodeMySpec.McpServers.Issues.Tools.GetIssue)
  component(CodeMySpec.McpServers.Issues.Tools.AcceptIssue)
  component(CodeMySpec.McpServers.Issues.Tools.DismissIssue)
  component(CodeMySpec.McpServers.Issues.Tools.ResolveIssue)

  # Personas — account-scoped persona library
  component(CodeMySpec.McpServers.Personas.Tools.CreatePersona)
  component(CodeMySpec.McpServers.Personas.Tools.UpdatePersona)
  component(CodeMySpec.McpServers.Personas.Tools.DeletePersona)
  component(CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory)
  component(CodeMySpec.McpServers.Personas.Tools.UnlinkPersonaFromStory)
  component(CodeMySpec.McpServers.Personas.Tools.ListPersonas)
  component(CodeMySpec.McpServers.Personas.Tools.GetPersona)

  # BDD Rules — Three Amigos session artifacts (blue + green + red cards).
  # Lives under BddRules namespace to disambiguate from CodeMySpec.Rules
  # (the coding-convention markdown rules consumed by agent task prompts).
  component(CodeMySpec.McpServers.BddRules.Tools.AddRule)
  component(CodeMySpec.McpServers.BddRules.Tools.DeleteRule)
  component(CodeMySpec.McpServers.BddRules.Tools.ListRules)
  component(CodeMySpec.McpServers.BddRules.Tools.AddScenario)
  component(CodeMySpec.McpServers.BddRules.Tools.AddQuestion)
  component(CodeMySpec.McpServers.BddRules.Tools.ListQuestions)
  component(CodeMySpec.McpServers.BddRules.Tools.ResolveQuestion)
  component(CodeMySpec.McpServers.BddRules.Tools.GetStoryGherkin)
end
