defmodule CodeMySpec.AgentPerformance.Stage do
  @moduledoc """
  Which cycle-time stage a session type belongs to.

  A story moves through five named stages on its way to main: specs,
  build, certification, QA and promotion. Every `AgentTasks` module maps
  to exactly one of them, or to `:other` for the handful -- research,
  project setup, issue triage -- that are not part of a story's own
  cycle at all.
  """

  alias CodeMySpec.AgentTasks

  @specs [
    AgentTasks.StoryInterview,
    AgentTasks.ThreeAmigos,
    AgentTasks.ContextComponentSpecs,
    AgentTasks.WriteBddSpecs,
    AgentTasks.FixBddSpecs,
    AgentTasks.FixAllBddSpecs,
    AgentTasks.SpexBoundaryReady,
    AgentTasks.ArchitectureDesign,
    AgentTasks.DesignUi
  ]

  @build [
    AgentTasks.ComponentCode,
    AgentTasks.ComponentTest,
    AgentTasks.CodeGeneration,
    AgentTasks.DevelopContext,
    AgentTasks.DevelopController,
    AgentTasks.DevelopLiveContext,
    AgentTasks.DevelopLiveView,
    AgentTasks.StartImplementation,
    AgentTasks.LinkStoryComponent,
    AgentTasks.FixIssues,
    AgentTasks.FixStoryIssues,
    AgentTasks.IssueFix
  ]

  @certification [AgentTasks.ReadyForQa]

  @qa [
    AgentTasks.QaApp,
    AgentTasks.QaStory,
    AgentTasks.QaJourney,
    AgentTasks.QaSetup,
    AgentTasks.QaIntegrationPlan,
    AgentTasks.IssueQa
  ]

  @promotion [
    AgentTasks.PromoteWork,
    AgentTasks.Release,
    AgentTasks.IssuePromote,
    AgentTasks.Deploy
  ]

  @type t :: :specs | :build | :certification | :qa | :promotion | :other

  @doc "The stage a task's session type belongs to."
  @spec of(module() | nil) :: t()
  def of(type) when type in @specs, do: :specs
  def of(type) when type in @build, do: :build
  def of(type) when type in @certification, do: :certification
  def of(type) when type in @qa, do: :qa
  def of(type) when type in @promotion, do: :promotion
  def of(_type), do: :other

  @doc "The five named stages, in the order a story moves through them."
  @spec names() :: [t()]
  def names, do: [:specs, :build, :certification, :qa, :promotion]
end
