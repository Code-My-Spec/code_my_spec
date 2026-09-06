defmodule CodeMySpecTest.RecordingAgentTransport do
  @moduledoc """
  An agent transport that sends what it was asked to deliver to the test.

  `InProcessAgentTransport` is the default in `config/test.exs` and it really
  runs an agent — right for exercising a turn, and far more machinery than a
  test that only wants to know *whether* a message was dispatched and what it
  said.

  Install it with `Application.put_env(:code_my_spec, :agent_transport,
  __MODULE__)` and `async: false`. The key is global, so a concurrent test would
  pick up whichever transport the other one installed — the same reason
  `AgentProcessSpexHelpers` restores the previous value on exit rather than
  assuming the default.
  """

  @behaviour CodeMySpec.Agents.Transport

  @doc "Route deliveries to the calling process."
  def listen, do: :persistent_term.put({__MODULE__, :owner}, self())

  @impl true
  def message_agent(_working_copy_id, agent, message, _timeout) do
    send(owner(), {:agent_message, agent.id, message})
    {:ok, "recorded"}
  end

  @impl true
  def dispatch_message(_working_copy_id, agent, ref, message, _timeout) do
    send(owner(), {:agent_dispatch, agent.id, ref, message})
    {:ok, :queued}
  end

  @impl true
  def withdraw_message(_working_copy_id, _agent, _ref, _timeout), do: :ok

  @impl true
  def start_agent(_working_copy_id, _agent, _timeout),
    do: {:ok, %{os_pid: 4242, os_boot_id: "recorded"}}

  @impl true
  def stop_agent(_working_copy_id, _agent, _timeout), do: :ok

  @impl true
  def call_machine_tool(_working_copy_id, _tool, _arguments, _timeout), do: {:ok, "recorded"}

  @impl true
  def create_working_copy(_candidates, _request, _timeout), do: {:error, :no_harness}

  # The test process when one registered, and otherwise the caller — a delivery
  # with nobody listening should be inert rather than a crash in a code path the
  # test is not looking at.
  defp owner, do: :persistent_term.get({__MODULE__, :owner}, self())
end
