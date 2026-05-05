defmodule CodeMySpec.McpServers.ProductManagerServer do
  @moduledoc false
  use Anubis.Server,
    name: "product-manager-server",
    version: "1.0.0",
    capabilities: [:tools]

  # -- Stories: CRUD + organization ----------------------------------------
  component(CodeMySpec.McpServers.Stories.Tools.CreateStory)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateStory)
  component(CodeMySpec.McpServers.Stories.Tools.DeleteStory)
  component(CodeMySpec.McpServers.Stories.Tools.GetStory)
  component(CodeMySpec.McpServers.Stories.Tools.ListStories)
  component(CodeMySpec.McpServers.Stories.Tools.ListStoryTitles)

  # -- Acceptance criteria -------------------------------------------------
  component(CodeMySpec.McpServers.Stories.Tools.AddCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.UpdateCriterion)
  component(CodeMySpec.McpServers.Stories.Tools.DeleteCriterion)

  # -- Tagging -------------------------------------------------------------
  component(CodeMySpec.McpServers.Stories.Tools.ListProjectTags)
  component(CodeMySpec.McpServers.Stories.Tools.TagStories)

  # -- Sessions ------------------------------------------------------------
  component(CodeMySpec.McpServers.Stories.Tools.StartStoryInterview)
  component(CodeMySpec.McpServers.Stories.Tools.StartStoryReview)
  component(CodeMySpec.McpServers.Stories.Tools.StartThreeAmigosSession)

  # -- Three Amigos workflow tools (rules, scenarios, questions) ----------
  # Surfaced on the PM server so the agent can drive a full Three Amigos
  # session without crossing into another server.
  component(CodeMySpec.McpServers.BddRules.Tools.AddRule)
  component(CodeMySpec.McpServers.BddRules.Tools.DeleteRule)
  component(CodeMySpec.McpServers.BddRules.Tools.ListRules)
  component(CodeMySpec.McpServers.BddRules.Tools.AddScenario)
  component(CodeMySpec.McpServers.BddRules.Tools.AddQuestion)
  component(CodeMySpec.McpServers.BddRules.Tools.ListQuestions)
  component(CodeMySpec.McpServers.BddRules.Tools.ResolveQuestion)
  component(CodeMySpec.McpServers.BddRules.Tools.GetStoryGherkin)

  # -- Personas (account-scoped library + story linkage) ------------------
  component(CodeMySpec.McpServers.Personas.Tools.CreatePersona)
  component(CodeMySpec.McpServers.Personas.Tools.UpdatePersona)
  component(CodeMySpec.McpServers.Personas.Tools.DeletePersona)
  component(CodeMySpec.McpServers.Personas.Tools.ListPersonas)
  component(CodeMySpec.McpServers.Personas.Tools.GetPersona)
  component(CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory)
  component(CodeMySpec.McpServers.Personas.Tools.UnlinkPersonaFromStory)

  # -- Issue triage --------------------------------------------------------
  component(CodeMySpec.McpServers.Issues.Tools.ListIssues)
  component(CodeMySpec.McpServers.Issues.Tools.GetIssue)
  component(CodeMySpec.McpServers.Issues.Tools.AcceptIssue)
  component(CodeMySpec.McpServers.Issues.Tools.DismissIssue)
  component(CodeMySpec.McpServers.Issues.Tools.ResolveIssue)
  component(CodeMySpec.McpServers.Stories.Tools.TriageIssues)
end
