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
  alias CodeMySpec.Agents.LaunchRequest
  alias CmsHarnessTest.Machine

  @impl true
  def start_agent(_working_copy_id, agent, _timeout) do
    Machine.ensure_supervisor()

    # The same map the channel would carry, built the same way. Assembling a
    # second one here is what made this double agree with itself and with
    # nothing else — a field added to the wire reached the socket and not the
    # suite, so a criterion driving this proved nothing about production.
    #
    # A key is put on top for providers that need one: nothing here chats to
    # the agent, so none is ever spent, and a provider that needs a key and
    # does not get one is a different failure with its own criterion.
    request =
      agent
      |> LaunchRequest.for()
      |> Map.put_new("api_key", "unused-in-process")

    Agents.launch(request)
  end

  @impl true
  def stop_agent(_working_copy_id, agent, _timeout) do
    Machine.ensure_supervisor()
    Agents.halt(agent.id)
  end

  @impl true
  def message_agent(_working_copy_id, agent, message, timeout) do
    Machine.ensure_supervisor()
    Agents.message(agent.id, message, timeout)
  end

  @impl true
  def dispatch_message(_working_copy_id, agent, ref, message, timeout) do
    Machine.ensure_supervisor()
    Agents.send_message(agent.id, ref, message, timeout)
  end

  @impl true
  def withdraw_message(_working_copy_id, agent, ref, _timeout) do
    Machine.ensure_supervisor()
    Agents.withdraw(agent.id, ref)
  end
  @impl true
  def call_machine_tool(_working_copy_id, tool, arguments, _timeout) do
    # In this VM the browser is whatever the local MCP transport was told to
    # offer, so the round trip is the part that is stood in for and the answer
    # is the one a criterion asserts on.
    CmsHarness.Mcp.Transport.Local.call({CmsHarness.Mcp.Transport.Local, :browser}, tool, arguments)
  end

end
