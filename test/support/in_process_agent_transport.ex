defmodule CodeMySpecTest.InProcessAgentTransport do
  @moduledoc """
  The server talking to the machine without a socket in between.

  Every step is the real one except the wire: `CodeMySpec.Agents` asks a
  transport, this transport is `CmsHarness.Agents`, and that starts a real
  supervised agent. What is removed is the channel, and only the channel.

  That matters more than it sounds for this story's criteria. They are about
  whether stopping an agent stops the thing that spends money, and a double
  that returned `:ok` without a process would assert nothing — which is exactly
  how three shipped instances of that defect passed everything asked of them.
  """

  @behaviour CodeMySpec.Agents.Transport

  alias CmsHarness.Agents

  @impl true
  def start_agent(_working_copy_id, agent, _timeout) do
    Agents.launch(%{
      "agent_id" => agent.id,
      "provider" => agent.provider,
      "working_copy" => agent.working_copy,
      "role" => agent.role,
      # Never used: nothing here chats to the agent, so no provider is reached.
      # It is present because a provider that needs a key and does not get one
      # is a different failure with its own criterion.
      "api_key" => "unused-in-process"
    })
  end

  @impl true
  def stop_agent(_working_copy_id, agent, _timeout) do
    Agents.halt(agent.id)
  end
end
