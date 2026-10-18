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
      CodeMySpec.Agents.Tools.AskUserQuestion,
      CodeMySpec.Agents.Tools.AssignSubagent,
      CodeMySpec.Agents.Tools.AssignTask,
      CodeMySpec.Agents.Tools.CancelTask,
      CodeMySpec.Agents.Tools.CheckAnswer,
      CodeMySpec.Agents.Tools.EvaluateTask,
      CodeMySpec.Agents.Tools.ListAgents,
      CodeMySpec.Agents.Tools.ListSessionSubagents,
      CodeMySpec.Agents.Tools.ListTasks,
      CodeMySpec.Agents.Tools.ListUserQuestions,
      CodeMySpec.Agents.Tools.MessageAgent,
      CodeMySpec.Agents.Tools.RegisterSession,
      CodeMySpec.Agents.Tools.RejectOffer,
      CodeMySpec.Agents.Tools.RetireAgent,
      CodeMySpec.Agents.Tools.ShowInPanel,
      CodeMySpec.Agents.Tools.StartAnalysis,
      CodeMySpec.Agents.Tools.StartTask,
      CodeMySpec.Agents.Tools.TapOut,
      CodeMySpec.Agents.Tools.TurnOffAgent,
      CodeMySpec.Agents.Tools.TurnOnAgent,
      CodeMySpec.Agents.Tools.WithdrawMessage,
      CodeMySpec.Agents.Tools.WithdrawQuestion
    ]
  end
end
