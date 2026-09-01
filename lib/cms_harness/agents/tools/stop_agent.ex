defmodule CmsHarness.Agents.Tools.StopAgent do
  @moduledoc """
  End one agent you started.

  The counterpart to `start_agent`: an agent able to start and unable to stop
  leaves the fleet the exclusion was worried about, only slower.
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "stop_agent",
    nothing_to: "no agent it can reach"

  @impl true
  def description do
    """
    Stop one running agent by id.

    One, and only one. Stop an agent whose work is done or whose work you are
    withdrawing — a stopped agent releases its working copy and stops spending.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        agent_id: %{type: "string", description: "Id of the agent to stop"}
      },
      required: ["agent_id"]
    }
  end
end
