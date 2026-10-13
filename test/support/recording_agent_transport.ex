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

  @doc """
  Route deliveries to the calling process.

  A dispatch this test triggers can run on a fire-and-forget Task
  (`Agents.dispatch_admitted`'s async branch). If that Task is still in
  flight when the *next* test calls `listen/0` and overwrites the global
  owner, its eventual `dispatch_message`/`request_work_turn` call lands in
  that next test's mailbox instead of this one's -- a message with the
  wrong agent id, matched by `assert_receive`'s loose pattern (hit
  2026-10-11, story 1091's promotion batch). Waiting here, at `on_exit`,
  for whatever Task started during this test to finish first closes that
  for every caller, without waiting on unrelated concurrent async tests'
  own tasks under the same shared supervisor.
  """
  def listen do
    before = CodeMySpec.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()
    :persistent_term.put({__MODULE__, :owner}, self())
    ExUnit.Callbacks.on_exit(fn -> drain_since(before) end)
  end

  defp drain_since(before, deadline \\ System.monotonic_time(:millisecond) + 500) do
    new_children =
      CodeMySpec.TaskSupervisor
      |> Task.Supervisor.children()
      |> MapSet.new()
      |> MapSet.difference(before)

    cond do
      Enum.empty?(new_children) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        drain_since(before, deadline)
    end
  end

  @impl true
  def dispatch_message(_working_copy_id, agent, ref, message, _timeout) do
    send(owner(), {:agent_dispatch, agent.id, ref, message})
    {:ok, :started}
  end

  @impl true
  def interrupt_turn(_working_copy_id, agent) do
    send(owner(), {:turn_interrupted, agent.id})
    :ok
  end

  @impl true
  def request_work_turn(_copy, agent, ref, message, _timeout) do
    send(owner(), {:work_turn_requested, agent.id, ref, message})
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

  # The test process when one registered, and otherwise the caller — a delivery
  # with nobody listening should be inert rather than a crash in a code path the
  # test is not looking at.
  defp owner, do: :persistent_term.get({__MODULE__, :owner}, self())
end
