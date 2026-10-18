defmodule CmsHarness.Agents.Engine do
  @moduledoc """
  The Alloy agent: an agent process this harness runs itself, answering the
  agent contract in `CmsHarness.Agents`. Starting, stopping and what only an
  Alloy loop holds (its tools, its MCP client, its history) live here.

  The process is `Engine.Server`; its state transitions live in `Engine.Impl`.
  """

  alias CmsHarness.Agents.Engine.Impl
  alias CmsHarness.Agents.Engine.Server

  defdelegate start(opts), to: Impl
  defdelegate describe_start_failure(agent_id, working_copy, reason), to: Impl

  def agent_tools(agent_id), do: optional_call(agent_id, :tools, [])
  def mcp_client(agent_id), do: optional_call(agent_id, :mcp_client, nil)

  def history(agent_id), do: call(agent_id, :history)

  defdelegate stop(agent_id), to: Impl
  defdelegate tools(opts), to: Impl
  defdelegate tool_name(tool), to: Impl

  # Kept public for the harness lifecycle tests; normal callers use `stop/1`.
  defdelegate terminate(reason, state), to: Server

  defp call(agent_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- CmsHarness.Agents.whereis(agent_id),
         do: GenServer.call(pid, message, timeout)
  end

  defp optional_call(agent_id, message, fallback) do
    case CmsHarness.Agents.whereis(agent_id) do
      {:ok, pid} -> GenServer.call(pid, message)
      _ -> fallback
    end
  end
end
