defmodule CodeMySpec.Agents.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AgentTasks,
      CodeMySpec.Agents,
      CodeMySpec.Agents.Agent,
      CodeMySpec.Agents.RoleProfile,
      CodeMySpec.Analysis,
      CodeMySpec.BootVersion,
      CodeMySpec.Components,
      CodeMySpec.Configurations,
      CodeMySpec.Conversations,
      CodeMySpec.Embeddings,
      CodeMySpec.Notifications,
      CodeMySpec.Qa,
      CodeMySpec.Requirements,
      CodeMySpec.ScreenState,
      CodeMySpec.Sessions,
      CodeMySpec.Stories,
      CodeMySpec.TaskOwner,
      CodeMySpec.Tools,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ]

  def all do
    [
      CodeMySpec.Agents.Tools.AnswerNotification,
      CodeMySpec.Agents.Tools.AskUserQuestion,
      CodeMySpec.Agents.Tools.AssignSubagent,
      CodeMySpec.Agents.Tools.AssignTask,
      CodeMySpec.Agents.Tools.Cadence,
      CodeMySpec.Agents.Tools.CancelTask,
      CodeMySpec.Agents.Tools.CheckAnswer,
      CodeMySpec.Agents.Tools.CheckIn,
      CodeMySpec.Agents.Tools.CheckMachinery,
      CodeMySpec.Agents.Tools.CompletionHandoff,
      CodeMySpec.Agents.Tools.EscalateQuestion,
      CodeMySpec.Agents.Tools.EvaluateTask,
      CodeMySpec.Agents.Tools.ListAgentWork,
      CodeMySpec.Agents.Tools.ListAgents,
      CodeMySpec.Agents.Tools.ListNotifications,
      CodeMySpec.Agents.Tools.ListOffers,
      CodeMySpec.Agents.Tools.ListSessionSubagents,
      CodeMySpec.Agents.Tools.ListTasks,
      CodeMySpec.Agents.Tools.ListUserQuestions,
      CodeMySpec.Agents.Tools.MessageAgent,
      CodeMySpec.Agents.Tools.ReadAgentConversation,
      CodeMySpec.Agents.Tools.ReadyStoriesWithoutEpic,
      CodeMySpec.Agents.Tools.RegisterSession,
      CodeMySpec.Agents.Tools.RejectOffer,
      CodeMySpec.Agents.Tools.ResetDocPackages,
      CodeMySpec.Agents.Tools.RestartAgent,
      CodeMySpec.Agents.Tools.ResumeIssueQa,
      CodeMySpec.Agents.Tools.RetireAgent,
      CodeMySpec.Agents.Tools.SearchAnswers,
      CodeMySpec.Agents.Tools.SetAgentContinuous,
      CodeMySpec.Agents.Tools.ShowInPanel,
      CodeMySpec.Agents.Tools.StartAnalysis,
      CodeMySpec.Agents.Tools.StartTask,
      CodeMySpec.Agents.Tools.TakeOverWork,
      CodeMySpec.Agents.Tools.TapOut,
      CodeMySpec.Agents.Tools.TurnOffAgent,
      CodeMySpec.Agents.Tools.TurnOnAgent,
      CodeMySpec.Agents.Tools.ValidationHold,
      CodeMySpec.Agents.Tools.WithdrawMessage,
      CodeMySpec.Agents.Tools.WithdrawQuestion
    ]
  end
end
