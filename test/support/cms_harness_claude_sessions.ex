defmodule CmsHarnessTest.ClaudeSessions do
  @moduledoc """
  Claude Code's agent list as a test says it is (stories 1123, 1124): what
  `claude agents --json` would say of one session, without running `claude`.

  Asked by session id, so tests running at once never see each other's
  sessions. A session no test has listed reads as unknown, and its terminal
  agent falls back to its socket, as it does when the list cannot be read.
  """

  @doc "List `session_id` as `status` (`busy`, `idle` or `waiting`)."
  @spec put(String.t(), String.t()) :: :ok
  def put(session_id, status), do: :persistent_term.put({__MODULE__, session_id}, {:ok, status})

  @doc "Take `session_id` off the list: its session ended."
  @spec gone(String.t()) :: :ok
  def gone(session_id), do: :persistent_term.put({__MODULE__, session_id}, :gone)

  @doc false
  def list(session_id), do: :persistent_term.get({__MODULE__, session_id}, :error)

  @doc """
  The harness looking at a terminal agent's session now, rather than at its
  next interval: what it does every fifteen seconds on its own.
  """
  @spec look(String.t()) :: :ok
  def look(agent_id) do
    with {:ok, pid} <- CmsHarness.Agents.whereis(agent_id), do: send(pid, :check)
    :ok
  end
end
