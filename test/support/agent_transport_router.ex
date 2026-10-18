defmodule CodeMySpecTest.AgentTransportRouter do
  @moduledoc """
  The test suite's agent transport: each test routes its own project.

  A test used to swap `:agent_transport` in the application env, which is one
  global key, so every such test ran `async: false` and a straggling Task from
  one test could deliver into the next one's mailbox. Here a test registers the
  transport for the project it created, from its own process:

      AgentTransportRouter.route(scope, CodeMySpecTest.RecordingAgentTransport)

  The registration dies with the test process, and no other test can see it,
  because no other test uses that project. A project nobody routed gets
  `CodeMySpecTest.InProcessAgentTransport`, the suite's default.

  The registering process is the route's owner: a recording transport sends
  what it was asked to deliver there.
  """

  @behaviour CodeMySpec.Agents.Transport

  @default CodeMySpecTest.InProcessAgentTransport

  @doc """
  Start the registry if it is not running. `mix spex` loads no test helper, so
  the first route starts it; it is unlinked so it outlives that test.
  """
  def start do
    case Registry.start_link(keys: :unique, name: __MODULE__) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  @doc """
  Route `project`'s agent traffic to `module`, owned by the calling process.

  `project` is a project id, a scope, or a context carrying a scope.
  Routing again replaces the earlier route.

  A dispatch this test triggers can run on a fire-and-forget Task
  (`Agents.dispatch_admitted`'s async branch). The registration dying with
  this process means a straggler can no longer land in a *different* live
  test's mailbox, but it can still try to use this test's DB sandbox
  connection after that connection has already been checked back in.
  Waiting here, at `on_exit`, for whatever such Task started during this
  route to finish closes that too.
  """
  @spec route(term(), module()) :: :ok
  def route(project, module) do
    id = project_id(project)
    start()
    Registry.unregister(__MODULE__, id)
    {:ok, _} = Registry.register(__MODULE__, id, module)

    before = CodeMySpec.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()
    ExUnit.Callbacks.on_exit(fn -> await_background_work(before) end)

    :ok
  end

  @doc """
  Route one agent's traffic to `module`, without touching its project's own
  route.

  `route/2` is the whole project (every agent on it, whichever copy): right
  for "this project's harness is gone", wrong for "this one agent's machine
  is unreachable while its teammates' are not" -- production dispatches by
  the agent's own `working_copy_id` (`Transport.Harness.holder/1`), so two
  agents on different copies of one project are independently reachable
  there. This gives a scenario the same granularity: an override checked
  ahead of the project's route, for calls that name this agent.
  """
  @spec route_agent(String.t(), module()) :: :ok
  def route_agent(agent_id, module) do
    start()
    Registry.unregister(__MODULE__, {:agent, agent_id})
    {:ok, _} = Registry.register(__MODULE__, {:agent, agent_id}, module)
    :ok
  end

  @doc """
  Block until every Task started under `CodeMySpec.TaskSupervisor` since
  `before` (a snapshot from `Task.Supervisor.children/1`) has finished, or
  half a second has passed.

  2aa4c832: this is now also done, unconditionally, by every sandboxed test
  through `CodeMySpecTest.DataCase.setup_sandbox/1` -- delegating here keeps
  this module's own documented wait (and the test proving it) unchanged
  rather than duplicating the loop.
  """
  @spec await_background_work(MapSet.t(), integer()) :: :ok
  def await_background_work(before, deadline \\ System.monotonic_time(:millisecond) + 500),
    do: CodeMySpecTest.DataCase.await_background_work(before, deadline)

  @doc "The process that routed `project_id`, or nil."
  @spec owner(String.t() | nil) :: pid() | nil
  def owner(project_id) do
    case lookup(project_id) do
      {pid, _module} -> pid
      nil -> nil
    end
  end

  defp transport(project_id, agent_id) do
    case agent_id && lookup({:agent, agent_id}) do
      {_pid, module} -> module
      _ -> project_transport(project_id)
    end
  end

  defp project_transport(project_id) do
    case lookup(project_id) do
      {_pid, module} -> module
      nil -> @default
    end
  end

  defp lookup(nil), do: nil

  defp lookup(project_id) do
    case Process.whereis(__MODULE__) && Registry.lookup(__MODULE__, project_id) do
      [entry] -> entry
      _none -> nil
    end
  end

  defp project_id(id) when is_binary(id), do: id
  defp project_id(%{active_project_id: id}) when is_binary(id), do: id
  defp project_id(%{scope: scope}), do: project_id(scope)

  defp copy_project_id(working_copy_id) do
    case CodeMySpec.WorkingCopies.fetch(working_copy_id) do
      {:ok, copy} -> copy.project_id
      _ -> nil
    end
  end

  @impl true
  def start_agent(copy, agent, timeout),
    do: transport(agent.project_id, agent.id).start_agent(copy, agent, timeout)

  @impl true
  def dispatch_message(copy, agent, ref, message, timeout),
    do: transport(agent.project_id, agent.id).dispatch_message(copy, agent, ref, message, timeout)

  @impl true
  def request_work_turn(copy, agent, ref, message, timeout),
    do: transport(agent.project_id, agent.id).request_work_turn(copy, agent, ref, message, timeout)

  @impl true
  def stop_agent(copy, agent, timeout),
    do: transport(agent.project_id, agent.id).stop_agent(copy, agent, timeout)

  @impl true
  def interrupt_turn(copy, agent) do
    module = transport(agent.project_id, agent.id)

    if function_exported?(module, :interrupt_turn, 2),
      do: module.interrupt_turn(copy, agent),
      else: {:error, :unsupported}
  end

  @impl true
  def call_machine_tool(copy, tool, arguments, timeout),
    do: project_transport(copy_project_id(copy)).call_machine_tool(copy, tool, arguments, timeout)

  @impl true
  def create_working_copy([first | _] = candidates, request, timeout),
    do:
      project_transport(copy_project_id(first)).create_working_copy(candidates, request, timeout)

  def create_working_copy([], request, timeout),
    do: @default.create_working_copy([], request, timeout)
end
