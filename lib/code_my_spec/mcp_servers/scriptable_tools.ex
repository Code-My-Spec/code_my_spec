defmodule CodeMySpec.McpServers.ScriptableTools do
  @moduledoc """
  Every tool reachable from a script, and nothing else.

  ## Why this is a server that is never started

  Story 971 shortens the tool list an agent is handed. The obvious way to do
  that — delete the registrations from `LocalServer` — takes the tools away
  from code mode too, because the catalog is built from a server's
  registrations. Unregistered is unreachable, not merely unadvertised, and the
  story would have removed 98 tools rather than moved them.

  So they are registered here instead. This module is never mounted on a
  transport and never supervised; it exists to be enumerated. Anubis computes
  the name, description, JSON Schema and input validation for each tool exactly
  as it does for a mounted server, so code mode gets the same registrations it
  had before, and `tools/list` never sees them.

  The alternative was hand-rolling that computation from `input_schema/0` and
  `__description__/0`, which would be a second implementation of something the
  framework already does correctly — and one that could drift.

  ## The split is the story's rule, not a preference

  A tool is here unless it is on the spine, and it is on the spine if it is one
  of the four every session walks in order, or if a script may not call it.
  That second half is load-bearing: `CodeMode.Catalog` refuses to bind
  `ask_user` and friends, so if they were also absent from `LocalServer` they
  would be reachable from nowhere at all.
  """

  use Anubis.Server,
    name: "codemyspec-scriptable",
    version: "1.0.0",
    capabilities: [:tools]

  component(CodeMySpec.McpServers.Issues.Tools.CreateIssue)
  component(CodeMySpec.McpServers.Health.Tools.ScriptHealth)
  component(CodeMySpec.McpServers.Issues.Tools.ListIssues)
  component(CodeMySpec.McpServers.Issues.Tools.GetIssue)
  component(CodeMySpec.McpServers.Issues.Tools.AcceptIssue)
  component(CodeMySpec.McpServers.Issues.Tools.DismissIssue)
  component(CodeMySpec.McpServers.Issues.Tools.ResolveIssue)
  component(CodeMySpec.McpServers.Issues.Tools.UpdateIssue)
  component(CodeMySpec.McpServers.Personas.Tools.CreatePersona)
  component(CodeMySpec.McpServers.Personas.Tools.UpdatePersona)
  component(CodeMySpec.McpServers.Personas.Tools.DeletePersona)
  component(CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory)
  component(CodeMySpec.McpServers.Personas.Tools.UnlinkPersonaFromStory)
  component(CodeMySpec.McpServers.Personas.Tools.ListPersonas)
  component(CodeMySpec.McpServers.Personas.Tools.GetPersona)
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
  component(CodeMySpec.McpServers.Qa.Tools.SubmitQaResult)
  component(CodeMySpec.McpServers.Qa.Tools.ListQaAttempts)
  component(CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt)
  component(CodeMySpec.McpServers.Problems.Tools.ClearProblems)
  component(CodeMySpec.McpServers.Problems.Tools.ListProblems)
  component(CodeMySpec.McpServers.Devops.Tools.DevopsStatus)
  component(CodeMySpec.McpServers.Devops.Tools.RunDevopsSetup)
  component(CodeMySpec.McpServers.Devops.Tools.GenerateDeployFiles)
  component(CodeMySpec.McpServers.Devops.Tools.ReadProjectFile)
  component(CodeMySpec.McpServers.Devops.Tools.WriteProjectFile)
  component(CodeMySpec.McpServers.Devops.Tools.EnsureEnvironment)
  component(CodeMySpec.McpServers.Devops.Tools.LinkServer)
  component(CodeMySpec.McpServers.Devops.Tools.ProvisionAccountServer)
  component(CodeMySpec.McpServers.Devops.Tools.ProviderRequest)
  component(CodeMySpec.McpServers.Devops.Tools.EnsureServerAccessKey)
  component(CodeMySpec.McpServers.Devops.Tools.AdoptRepository)
  component(CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep)
  component(CodeMySpec.McpServers.Devops.Tools.ReadDatabaseUrl)
  component(CodeMySpec.McpServers.Devops.Tools.ImportAgeKey)
  component(CodeMySpec.McpServers.Devops.Tools.ReadRegistryCredential)
  component(CodeMySpec.McpServers.Bootstrap.Tools.ListProjects)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InitProject)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallAgentsMd)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallRules)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallCredoChecks)
  component(CodeMySpec.McpServers.Bootstrap.Tools.InstallClaudeMd)
  component(CodeMySpec.McpServers.Stories.Tools.CreateStory)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateStory)
  component(CodeMySpec.McpServers.Stories.Tools.RetireStory)
  component(CodeMySpec.McpServers.Stories.Tools.RestoreStory)
  component(CodeMySpec.McpServers.Stories.Tools.GetStory)
  component(CodeMySpec.McpServers.Stories.Tools.ListStories)
  component(CodeMySpec.McpServers.Stories.Tools.ListStoryTitles)
  component(CodeMySpec.McpServers.Stories.Tools.SetStoryComponent)
  component(CodeMySpec.McpServers.Stories.Tools.ClearStoryComponent)
  component(CodeMySpec.McpServers.Stories.Tools.AnalyzeStoryLinkage)
  component(CodeMySpec.McpServers.Stories.Tools.AddCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.RetireCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.RestoreCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.GetCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.MoveCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.LinkCriterionToRule)
  component(CodeMySpec.McpServers.Stories.Tools.ListProjectTags)
  component(CodeMySpec.McpServers.Stories.Tools.TagStories)
  component(CodeMySpec.McpServers.Stories.Tools.CreateEpic)
  component(CodeMySpec.McpServers.Stories.Tools.ProposeEpic)

  # Placement, kept apart from approval on purpose — John: "let's have these as
  # separate actions, creating the working copy and assigning an epic to a
  # working copy". Listing exists so that choosing between copies can be a
  # judgement rather than a default.
  component(CodeMySpec.McpServers.Stories.Tools.ListWorkingCopies)
  component(CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy)
  component(CodeMySpec.McpServers.Stories.Tools.OffboardWorkingCopy)
  component(CodeMySpec.McpServers.Stories.Tools.SetWorkingCopyLoop)
  component(CodeMySpec.McpServers.Stories.Tools.SetActiveStory)
  component(CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy)

  # Story 1108: an agent on a copy can start, restart and stop its own copy's
  # app. Always the caller's own copy, never a parameter — see each tool's
  # own moduledoc for why that is what makes reaching another copy structural
  # rather than a check to bypass.
  component(CodeMySpec.McpServers.Stories.Tools.EnsureAppRunning)
  component(CodeMySpec.McpServers.Stories.Tools.RestartApp)
  component(CodeMySpec.McpServers.Stories.Tools.StopApp)

  # Criteria 1586/1587: sharing a preview is explicit, never automatic on an
  # app coming up — the same "an agent cannot reach another copy" scoping as
  # the three tools above.
  component(CodeMySpec.McpServers.Stories.Tools.ShareCopyApp)
  component(CodeMySpec.McpServers.Stories.Tools.UnshareCopyApp)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateEpic)
  component(CodeMySpec.McpServers.Stories.Tools.ListEpics)
  component(CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic)
  component(CodeMySpec.McpServers.Stories.Tools.SetEpicStoriesReady)
  component(CodeMySpec.McpServers.Stories.Tools.StartStoryInterview)
  component(CodeMySpec.McpServers.Stories.Tools.StartStoryReview)
  component(CodeMySpec.McpServers.Stories.Tools.StartThreeAmigosSession)
  component(CodeMySpec.McpServers.Stories.Tools.TriageIssues)
  component(CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraph)
  component(CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories)
  component(CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal)
  component(CodeMySpec.McpServers.Architecture.Tools.ShowArchitectureOverview)
  component(CodeMySpec.McpServers.Architecture.Tools.RegenerateProposal)
  component(CodeMySpec.McpServers.Components.Tools.CreateComponent)
  component(CodeMySpec.McpServers.Components.Tools.UpdateComponent)
  component(CodeMySpec.McpServers.Components.Tools.DeleteComponent)
  component(CodeMySpec.McpServers.Components.Tools.AddDependency)
  component(CodeMySpec.McpServers.Components.Tools.RemoveDependency)
  component(CodeMySpec.McpServers.Components.Tools.GetComponent)
  component(CodeMySpec.McpServers.Requirements.Tools.ListRequirements)
  component(CodeMySpec.McpServers.Requirements.Tools.ShowRequirement)
  component(CodeMySpec.McpServers.Requirements.Tools.ShowComponentRequirements)
  component(CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements)
  component(CodeMySpec.McpServers.Tasks.Tools.AssignTask)
  component(CodeMySpec.McpServers.Tasks.Tools.ListTasks)
  # Scriptable unlike the asking tools: it waits on nobody, and only touches the
  # caller's own question (8c91d5bc).
  component(CodeMySpec.McpServers.Tasks.Tools.WithdrawQuestion)
  component(CodeMySpec.McpServers.Tasks.Tools.RegisterSession)
  component(CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents)
  component(CodeMySpec.McpServers.Agents.Tools.ListAgents)

  # The main agent's view across its working copies, and the one act it can
  # take on what it finds there. Scripted rather than on the spine because the
  # spine is paid by every agent at connect and exactly one role calls these —
  # a coding agent has no use for its colleagues' open questions.
  component(CodeMySpec.McpServers.MainAgent.Tools.ListNotifications)
  component(CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion)
  component(CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork)
  component(CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation)
  component(CodeMySpec.McpServers.MainAgent.Tools.ListOffers)
  component(CodeMySpec.McpServers.MainAgent.Tools.ResetDocPackages)
  # The agent lifecycle. Main-only by role grant: `ToolSets` gives no other role
  # any of these.
  component(CodeMySpec.McpServers.Agents.Tools.StartAgent)
  component(CodeMySpec.McpServers.Agents.Tools.TurnOffAgent)
  component(CodeMySpec.McpServers.Agents.Tools.TurnOnAgent)
  component(CodeMySpec.McpServers.Agents.Tools.RetireAgent)
  component(CodeMySpec.McpServers.MainAgent.Tools.RestartAgent)
  component(CodeMySpec.McpServers.MainAgent.Tools.SetAgentContinuous)
  component(CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery)
  component(CodeMySpec.McpServers.MainAgent.Tools.SearchAnswers)
  component(CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification)
  component(CodeMySpec.McpServers.MainAgent.Tools.TakeOverWork)
  component(CodeMySpec.McpServers.MainAgent.Tools.ReadyStoriesWithoutEpic)
  component(CodeMySpec.McpServers.MainAgent.Tools.CheckIn)
  component(CodeMySpec.McpServers.MainAgent.Tools.Cadence)

  # Agents are given work by role rather than spawned on request, so what one
  # needs of another is a message, not a handle on its lifecycle.
  component(CodeMySpec.McpServers.Agents.Tools.MessageAgent)
  component(CodeMySpec.McpServers.Analysis.Tools.AwaitAnalysis)
  component(CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge)
  component(CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge)
  component(CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch)
  component(CodeMySpec.McpServers.Research.Tools.WebSearch)
  component(CodeMySpec.McpServers.Research.Tools.WebFetch)
  component(CodeMySpec.McpServers.Qa.Tools.CallMcpServer)
  # Story 1116 ("1082"): every agent role reads its own project's deployed
  # logs and traces. Granted to every role in `RoleProfile`, not main-only.
  component(CodeMySpec.McpServers.Observability.Tools.QueryLogs)
  component(CodeMySpec.McpServers.Observability.Tools.GetTrace)
  component(CodeMySpec.McpServers.Observability.Tools.SlowSpans)
  component(CodeMySpec.McpServers.Observability.Tools.ErrorSummary)
end
