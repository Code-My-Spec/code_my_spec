defmodule CmsHarness.Attachments.Session do
  @moduledoc false
  use GenServer, restart: :temporary

  alias CmsHarness.Attachments.Cleanup
  alias CmsHarness.Attachments.Operations

  def start_link({root, id}) do
    GenServer.start_link(__MODULE__, root,
      name: {:via, Registry, {CmsHarness.Registry, {:attachment, root, id}}}
    )
  end

  @impl true
  def init(root) do
    Process.flag(:trap_exit, true)
    {:ok, %{root: root, tasks: %{}}}
  end

  # The tools own their deadlines (bash's reaches an hour, as an agent's does);
  # this backstop matches the engine's `tool_timeout` and only catches a call
  # that never returns.
  @backstop :timer.hours(1) + 5_000

  @impl true
  def handle_call({:execute, payload}, from, state) do
    task = Task.async(fn -> Operations.execute(state.root, payload) end)
    timer = Process.send_after(self(), {:timeout, task.ref}, @backstop)
    entry = %{task: task, from: from, timer: timer}
    {:noreply, %{state | tasks: Map.put(state.tasks, task.ref, entry)}}
  end

  def handle_call(:disconnect, _from, state) do
    errors =
      Enum.flat_map(state.tasks, fn {_ref, entry} ->
        result = stop(entry)
        reply(entry.from, {:error, :attachment_disconnected})
        if result == :ok, do: [], else: [inspect(result)]
      end)

    reply = if errors == [], do: :ok, else: {:error, %{cleanup_errors: errors}}
    {:stop, :normal, reply, %{state | tasks: %{}}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    {entry, tasks} = Map.pop(state.tasks, ref)

    if entry do
      Process.cancel_timer(entry.timer)
      Process.demonitor(ref, [:flush])
      reply(entry.from, result)
    end

    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:timeout, ref}, state) do
    {entry, tasks} = Map.pop(state.tasks, ref)

    if entry do
      result = stop(entry)

      reply(
        entry.from,
        {:error, %{reason: "operation_timeout", cleanup: inspect(result)}}
      )
    end

    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {entry, tasks} = Map.pop(state.tasks, ref)

    if entry do
      Process.cancel_timer(entry.timer)

      reply(
        entry.from,
        {:error, %{reason: "operation_failed", detail: inspect(reason)}}
      )
    end

    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp stop(entry) do
    Process.cancel_timer(entry.timer)
    Process.demonitor(entry.task.ref, [:flush])
    Cleanup.stop(entry.task.pid)
  end

  defp reply(from, result), do: GenServer.reply(from, result)
end
