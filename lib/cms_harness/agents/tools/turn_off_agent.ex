defmodule CmsHarness.Agents.Tools.TurnOffAgent do
  @moduledoc """
  Turn one agent off.

  The counterpart to `start_agent`: an agent able to start and unable to stop
  leaves the fleet the exclusion was worried about, only slower. Off is the
  only deliberate stop (39af5611).
  """

  use CmsHarness.Agents.Tools.Direct,
    name: "turn_off_agent",
    nothing_to: "no agent it can reach"

  @impl true
  def description do
    """
    Turn one agent off by id, with an optional reason.

    One, and only one. Off ends its process, and until `turn_on_agent` nothing
    is delivered to it and nothing restarts it. Turn off an agent whose work is
    done or that must be held; it releases its working copy and stops spending.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        agent_id: %{type: "string", description: "Id of the agent to turn off"},
        reason: %{type: "string", description: "Optional. Why it is being turned off"}
      },
      required: ["agent_id"]
    }
  end
end
