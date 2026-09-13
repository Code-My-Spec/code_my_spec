defmodule CodeMySpecTest.RestartWatchingTransport do
  @moduledoc """
  Reports every start and stop it is asked for, in order.

  `RecordingAgentTransport` answers stops with a bare `:ok` and tells nobody, so
  a restart that skipped the stop entirely was indistinguishable from one that
  performed it — which is how a restart came to be a no-op against a live agent
  with every test still green (`e9f9a5ab`).

  Separate from that transport rather than added to it: the recorder's callers
  assert on delivered *messages*, and a stop arriving in the same mailbox would
  make those assertions depend on whether the agent had been restarted.
  """

  @behaviour CodeMySpec.Agents.Transport

  @doc "Route the machine's calls to the calling process."
  def listen, do: :persistent_term.put({__MODULE__, :owner}, self())

  @impl true
  def start_agent(_working_copy_id, agent, _timeout) do
    send(owner(), {:machine, :start, agent.id})
    {:ok, %{agent_id: agent.id}}
  end

  @impl true
  def stop_agent(_working_copy_id, agent, _timeout) do
    send(owner(), {:machine, :stop, agent.id})
    :ok
  end

  @impl true
  def message_agent(_working_copy_id, _agent, _message, _timeout), do: {:ok, "recorded"}

  @impl true
  def dispatch_message(_working_copy_id, _agent, _ref, _message, _timeout), do: {:ok, :queued}

  @impl true
  def withdraw_message(_working_copy_id, _agent, _ref, _timeout), do: :ok

  @impl true
  def call_machine_tool(_working_copy_id, _tool, _arguments, _timeout), do: {:ok, "recorded"}

  @impl true
  def create_working_copy(_candidates, _request, _timeout), do: {:error, :no_harness}

  defp owner, do: :persistent_term.get({__MODULE__, :owner})
end
