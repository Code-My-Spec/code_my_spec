defmodule CodeMySpec.McpServers.LocalServer do
  @moduledoc """
  Single MCP server for the local development environment.

  Exposes tools relevant to the local agent workflow.
  Story CRUD lives on the web server — only linking is local.

  ## Restart required after tool changes

  Adding or removing a `component(...)` registration below requires
  a **full `cms server` restart** to take effect. The running BEAM
  binds its tool registry at boot; reconnecting the MCP client
  (`/mcp` in Claude Code) only refreshes the client-side tool list,
  not the server-side handler module list. A freshly-added tool
  will appear in `tools/list` but invocation returns
  `MCP error -32603: Internal error` because the server has no
  handler module loaded for it.
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

  # Stories — full CRUD scoped to the local working dir
  component(CodeMySpec.McpServers.Stories.Tools.CreateStory)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateStory)
  component(CodeMySpec.McpServers.Stories.Tools.DeleteStory)
  component(CodeMySpec.McpServers.Stories.Tools.GetStory)
  component(CodeMySpec.McpServers.Stories.Tools.ListStories)
  component(CodeMySpec.McpServers.Stories.Tools.ListStoryTitles)
  component(CodeMySpec.McpServers.Stories.Tools.SetStoryComponent)
  component(CodeMySpec.McpServers.Stories.Tools.AnalyzeStoryLinkage)
  component(CodeMySpec.McpServers.Stories.Tools.AddCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.DeleteCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.MoveCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.LinkCriterionToRule)
  component(CodeMySpec.McpServers.Stories.Tools.ListProjectTags)
  component(CodeMySpec.McpServers.Stories.Tools.TagStories)

  # Epics — organizational grouping of stories, plus the one-shot bulk
  # release that controls how fast work enters the development graph.
  component(CodeMySpec.McpServers.Stories.Tools.CreateEpic)
  component(CodeMySpec.McpServers.Stories.Tools.ListEpics)
  component(CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic)
  component(CodeMySpec.McpServers.Stories.Tools.SetEpicStoriesReady)
  component(CodeMySpec.McpServers.Stories.Tools.StartStoryInterview)
  component(CodeMySpec.McpServers.Stories.Tools.StartStoryReview)
  component(CodeMySpec.McpServers.Stories.Tools.StartThreeAmigosSession)
  component(CodeMySpec.McpServers.Stories.Tools.TriageIssues)

  # Architecture
  component(CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraph)
  component(CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories)
  component(CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal)
  component(CodeMySpec.McpServers.Architecture.Tools.ShowArchitectureOverview)

  # Components — incremental architecture mutations (patch mode).
  # Deletion is intentionally not a tool: the architect deletes the
  # spec/impl/test files and ComponentSync removes the component on
  # the next sync. Dependency edges are likewise spec-driven — the
  # architect edits the source spec's `## Dependencies` section and
  # ComponentSync re-derives the graph.
  component(CodeMySpec.McpServers.Components.Tools.CreateComponent)
  component(CodeMySpec.McpServers.Components.Tools.UpdateComponent)

  # Requirements — discovery and sync
  component(CodeMySpec.McpServers.Requirements.Tools.ListRequirements)
  component(CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement)
  component(CodeMySpec.McpServers.Requirements.Tools.SyncProject)
  component(CodeMySpec.McpServers.Requirements.Tools.ShowRequirement)
  component(CodeMySpec.McpServers.Requirements.Tools.ShowComponentRequirements)
  component(CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements)

  # Tasks — start → evaluate lifecycle
  component(CodeMySpec.McpServers.Tasks.Tools.StartTask)
  component(CodeMySpec.McpServers.Tasks.Tools.AssignTask)
  component(CodeMySpec.McpServers.Tasks.Tools.EvaluateTask)
  component(CodeMySpec.McpServers.Tasks.Tools.ListTasks)
  component(CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents)
  component(CodeMySpec.McpServers.Tasks.Tools.AssignSubagent)
  component(CodeMySpec.McpServers.Tasks.Tools.CancelTask)
  component(CodeMySpec.McpServers.Tasks.Tools.TapOut)
  component(CodeMySpec.McpServers.Tasks.Tools.AskUser)
  component(CodeMySpec.McpServers.Tasks.Tools.AwaitAnalysis)

  # Knowledge — browse, read, and unified semantic search across every
  # embedded source (knowledge, project_knowledge, spec, rules, hexdocs:*).
  # Embedding is implicit in file sync — there's no manual embed_docs tool.
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
  component(CodeMySpec.McpServers.Issues.Tools.UpdateIssue)

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
  component(CodeMySpec.McpServers.BddRules.Tools.UpdateRule)
  component(CodeMySpec.McpServers.BddRules.Tools.DeleteRule)
  component(CodeMySpec.McpServers.BddRules.Tools.ListRules)
  component(CodeMySpec.McpServers.BddRules.Tools.AddScenario)
  component(CodeMySpec.McpServers.BddRules.Tools.UpdateScenario)
  component(CodeMySpec.McpServers.BddRules.Tools.AddQuestion)
  component(CodeMySpec.McpServers.BddRules.Tools.ListQuestions)
  component(CodeMySpec.McpServers.BddRules.Tools.ResolveQuestion)
  component(CodeMySpec.McpServers.BddRules.Tools.GetStoryGherkin)

  # QA — attempt submission and lifecycle
  component(CodeMySpec.McpServers.Qa.Tools.SubmitQaResult)
  component(CodeMySpec.McpServers.Qa.Tools.ListQaAttempts)
  component(CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt)

  # Problems — clear stale persisted problems that block the Stop hook
  # after the underlying file is fixed but a later run didn't re-check it.
  component(CodeMySpec.McpServers.Problems.Tools.ClearProblems)
end
