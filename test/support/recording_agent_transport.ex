defmodule CodeMySpecTest.RecordingAgentTransport do
  @moduledoc """
  An agent transport that sends what it was asked to deliver to the test.

  `InProcessAgentTransport` is the default in `config/test.exs` and it really
  runs an agent — right for exercising a turn, and far more machinery than a
  test that only wants to know *whether* a message was dispatched and what it
  said.

  Route a test's project to it with `listen/1`. Deliveries go to the process
  that routed the agent's project, so tests that each route their own project
  can run concurrently.
  """

  @behaviour CodeMySpec.Agents.Transport

  @doc "Route `project`'s deliveries to the calling process."
  def listen(project), do: CodeMySpecTest.AgentTransportRouter.route(project, __MODULE__)

  @impl true
  def dispatch_message(_working_copy_id, agent, ref, message, _timeout) do
    send(owner(agent), {:agent_dispatch, agent.id, ref, message})
    {:ok, :started}
  end

  @impl true
  def interrupt_turn(_working_copy_id, agent) do
    send(owner(agent), {:turn_interrupted, agent.id})
    :ok
  end

  @impl true
  def request_work_turn(_copy, agent, ref, message, _timeout) do
    send(owner(agent), {:work_turn_requested, agent.id, ref, message})
    {:ok, :started}
  end

  # `record_started/3` matches `%{agent_id: _id}` — "the machine confirms
  # the id it was asked to run, and that is the whole report" — and nothing
  # exercised this path through this transport before `restart_agent/2`.
  # The old `%{os_pid:, os_boot_id:}` shape predates that change and
  # crashed the moment something actually reached it.
  @impl true
  def start_agent(_working_copy_id, agent, _timeout),
    do: {:ok, %{agent_id: agent.id}}

  @impl true
  def stop_agent(_working_copy_id, _agent, _timeout), do: :ok

  @impl true
  def call_machine_tool(_working_copy_id, _tool, _arguments, _timeout), do: {:ok, "recorded"}

  @impl true
  def create_working_copy(_candidates, _request, _timeout), do: {:error, :no_harness}

  # The test that routed this agent's project, and otherwise the caller: a
  # delivery with nobody listening is inert rather than a crash in a code path
  # the test is not looking at.
  defp owner(agent), do: CodeMySpecTest.AgentTransportRouter.owner(agent.project_id) || self()
end
