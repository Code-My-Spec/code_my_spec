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
  alias CmsHarness.Channel

  defdelegate start(opts), to: Impl
  defdelegate describe_start_failure(agent_id, working_copy, reason), to: Impl

  @doc "Execute a claimed mailbox message, optionally waiting for its result."
  def send_message(agent_id, ref, message, timeout \\ 180_000, opts \\ []) do
    await? = Keyword.get(opts, :await, false)
    # `handle_call({:send, ...})` consumes through `Channel.mailbox/2` before it
    # replies at all, so waiting less than that round trip raises here on a
    # consume that was merely slow, not refused -- which crashed the bare task
    # meant to report the outcome and left a genuinely-started turn answered as
    # a timeout instead (32185981).
    admission_timeout = Channel.mailbox_timeout() + 3_000
    call_timeout = if await?, do: timeout + admission_timeout, else: admission_timeout
    call(agent_id, {:send, ref, message, timeout, await?}, call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, :message_timed_out}
  end

  def request_work_turn(agent_id, ref, message, timeout \\ 180_000),
    do: call(agent_id, {:work_available, ref, message, timeout})

  def status(agent_id), do: call(agent_id, :status)

  @doc "Stop the running turn for a message sent now (story 1051). `:idle` when none runs."
  def interrupt(agent_id), do: call(agent_id, :interrupt)

  def agent_tools(agent_id), do: optional_call(agent_id, :tools, [])
  def mcp_client(agent_id), do: optional_call(agent_id, :mcp_client, nil)

  def history(agent_id) do
    with {:ok, alloy} <- call(agent_id, :alloy) do
      {:ok, AlloyServer.messages(alloy)}
    end
  catch
    :exit, {:timeout, _} -> {:error, :busy}
  end

  defdelegate stop(agent_id), to: Impl

  defdelegate whereis(agent_id), to: State

  def running, do: State.running()
  def running?(agent_id), do: match?({:ok, _}, State.whereis(agent_id))
  defdelegate tools(opts), to: Impl
  defdelegate tool_name(tool), to: Impl

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
