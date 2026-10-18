defmodule CodeMySpec.Agents.Tools do
  @moduledoc """
  The tools an agent calls in this domain, for `CodeMySpec.ToolLibrary`.
  Its own boundary, so what the tools read does not become the core's deps.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Agents.Agent,
      CodeMySpec.Agents.RoleProfile,
      CodeMySpec.Tools,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ]

  def all do
    [
      CodeMySpec.Agents.Tools.ListAgents,
      CodeMySpec.Agents.Tools.MessageAgent,
      CodeMySpec.Agents.Tools.RejectOffer,
      CodeMySpec.Agents.Tools.RetireAgent,
      CodeMySpec.Agents.Tools.TurnOffAgent,
      CodeMySpec.Agents.Tools.TurnOnAgent,
      CodeMySpec.Agents.Tools.WithdrawMessage
    ]
  end
end
