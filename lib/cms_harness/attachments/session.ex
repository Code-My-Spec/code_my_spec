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

  @impl true
  def handle_call({:execute, payload}, from, state) do
    owner = self()
    token = make_ref()

    task =
      Task.async(fn ->
        Operations.execute(state.root, payload, &send(owner, {:operation_result, token, &1}))
      end)

    timeout = timeout(payload["timeout_ms"])
    timer = Process.send_after(self(), {:timeout, task.ref}, timeout)
    entry = %{task: task, from: from, timer: timer, token: token}
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
  def handle_info({:operation_result, token, result}, state) do
    tasks =
      Map.new(state.tasks, fn {ref, entry} ->
        if entry.token == token do
          Process.cancel_timer(entry.timer)
          reply(entry.from, result)
          {ref, %{entry | from: nil}}
        else
          {ref, entry}
        end
      end)

    {:noreply, %{state | tasks: tasks}}
  end

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

  defp reply(nil, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

  defp timeout(value) when is_integer(value), do: min(max(value, 1), 120_000)
  defp timeout(_), do: 30_000
end
