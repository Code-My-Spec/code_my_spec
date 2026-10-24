defmodule CodeMySpec.AppInstances.Tools.StopApp do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.AppInstances.AppRunLock
  alias CodeMySpec.AppInstances
  alias CodeMySpec.AppInstances.Tools.Starter
  alias CodeMySpec.AppInstances.Tools.Target

  @timeout to_timeout(second: 30)

  @impl true
  def name, do: "stop_app"

  @impl true
  def description do
    """
    Stop the caller's own copy of the app.

    By default this uses the caller's source checkout's default app instance.
    `instance_id` may select another instance only when it belongs to that same
    checkout; ownership is verified before the runtime is contacted. A copy
    with nothing running answers success too, same as `AppTransport.stop_app/2`.

    ## Returns when the run starts, not when it finishes

    Stopping is normally fast, but this used to hold the code-mode sandbox's
    entire 30s budget inline with no margin to even return an answer
    afterward (issue f2977826, batch 2 of 4f7929e4). The spawned task claims
    this working copy's own lock -- shared with `restart_app` and
    `ensure_app_running`, since all three touch the same app process -- and
    only then acks: the reply is "started" or "already running"; an agent
    that started it is messaged the outcome, any other caller calls this
    tool again to check.
    """
  end

  @impl true
  def params do
    %{
      instance_id:
        {:meta, :string, [description: "App instance UUID from `list_working_copies`."]}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> stop(scope, context, Map.get(params, :instance_id))
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp stop(scope, context, instance_id) do
    with {:ok, instance} <- Target.own_default(scope, context, instance_id) do
      starter = Starter.new(scope, context, "stop")
      instance.id |> start_stop_async(starter, scope) |> reply(context)
    else
      _ -> {:error, "This call has no working copy of its own, so there is nothing here to stop."}
    end
  end

  # `working_copies_app_run_async` -- `config/test.exs` pins it false, so
  # every existing test keeps running this inline, on the caller's own
  # connection.
  defp start_stop_async(id, starter, scope) do
    case Application.get_env(:code_my_spec, :working_copies_app_run_async, true) do
      true -> spawn_stop_async(id, starter, scope)
      _ -> AppRunLock.with_lock(id, fn -> do_stop(scope, id) end)
    end
  end

  # Same handshake as `RunProvisioningStep.spawn_step_async/5`: the spawned
  # task claims `AppRunLock` first and only then signals, so the caller
  # learns "running" or "refused" in milliseconds, out of reach of this
  # call's own timeouts.
  defp spawn_stop_async(id, starter, scope) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        AppRunLock.with_lock(
          id,
          fn ->
            send(parent, {ref, :locked})
            do_stop(scope, id)
          end,
          Starter.lock_holder(starter)
        )
        |> case do
          {:error, {:already_running, _}} = refused ->
            send(parent, {ref, refused})

          finished ->
            Starter.tell(starter, outcome_message(finished))
        end
      end)

    receive do
      {^ref, :locked} -> {:ok, :started}
      {^ref, {:error, {:already_running, _}} = refused} -> refused
    after
      5_000 -> {:error, :lock_handshake_timeout}
    end
  end

  defp do_stop(scope, id) do
    case AppInstances.stop(scope, id, @timeout) do
      :ok -> {:ok, "Stopped."}
      {:error, reason} -> {:error, "Could not stop the app: #{inspect(reason)}"}
    end
  end

  defp reply({:ok, :started}, context) do
    {:ok, "Stopping -- #{Starter.then_what(context[:agent_id])}"}
  end

  # The synchronous (test-mode) outcome: `do_stop/1`'s own result.
  defp reply({:ok, text}, _context), do: {:ok, text}

  defp reply({:error, {:already_running, started_at}}, _context) do
    since = started_at && " (started #{started_at})"

    {:error,
     "a run is already in progress for this copy's app#{since} -- call this " <>
       "tool again to check, rather than retrying"}
  end

  defp reply({:error, :lock_handshake_timeout}, _context) do
    {:error, "could not confirm stopping started -- try again shortly"}
  end

  defp reply({:error, reason}, _context), do: {:error, reason}

  @doc false
  def outcome_message({:ok, text}), do: text
  def outcome_message({:error, reason}), do: reason

  defp refusal(:missing_active_project) do
    "This call names no project, so there is no working copy to stop an app for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
