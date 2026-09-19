defmodule CmsHarness.Agents.Engine do
  @moduledoc """
  Public API for one harness-owned agent.

  Callers use this module rather than the process implementation. The current
  execution strategy is `Engine.Server`; the agent's state transitions live in
  `Engine.Impl`.
  """

  alias Alloy.Agent.Server, as: AlloyServer
  alias CmsHarness.Agents.Engine.Impl
  alias CmsHarness.Agents.Engine.Server
  alias CmsHarness.Agents.Engine.State

  defdelegate start(opts), to: Impl
  defdelegate describe_start_failure(agent_id, working_copy, reason), to: Impl
  def chat(agent_id, message), do: chat(agent_id, message, 180_000)

  def chat(agent_id, message, timeout),
    do: call(agent_id, {:chat, message, timeout}, timeout + 5_000)

  def send_message(agent_id, ref, message), do: send_message(agent_id, ref, message, 180_000)

  def send_message(agent_id, ref, message, timeout),
    do: call(agent_id, {:send, ref, message, timeout})

  def withdraw(agent_id, ref), do: call(agent_id, {:withdraw, ref})
  def status(agent_id), do: call(agent_id, :status)

  def agent_tools(agent_id), do: optional_call(agent_id, :tools, [])
  def mcp_client(agent_id), do: optional_call(agent_id, :mcp_client, nil)

  def history(agent_id) do
    with {:ok, alloy} <- call(agent_id, :alloy) do
      {:ok, AlloyServer.messages(alloy)}
    end
  catch
    :exit, {:timeout, _} -> {:error, :busy}
  end

  def stop(agent_id) do
    with {:ok, pid} <- State.whereis(agent_id),
         do: DynamicSupervisor.terminate_child(CmsHarness.AgentSupervisor, pid)
  end

  def running, do: State.running()
  def running?(agent_id), do: match?({:ok, _}, State.whereis(agent_id))
  defdelegate tools(opts), to: Impl

  # Kept public for the harness lifecycle tests; normal callers use `stop/1`.
  defdelegate terminate(reason, state), to: Server

  defp call(agent_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- State.whereis(agent_id), do: GenServer.call(pid, message, timeout)
  end

  defp optional_call(agent_id, message, fallback) do
    case State.whereis(agent_id) do
      {:ok, pid} -> GenServer.call(pid, message)
      _ -> fallback
    end
  end
end
