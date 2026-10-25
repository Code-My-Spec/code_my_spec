defmodule CodeMySpec.AppInstances.Tools.RestartApp do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.AppInstances
  alias CodeMySpec.CodeMode.Sandbox
  alias CodeMySpec.AppInstances.AppRunLock
  alias CodeMySpec.AppInstances.Tools.Starter
  alias CodeMySpec.AppInstances.Tools.Target

  # A restart waits for a compile and a boot, which is why this was once three
  # minutes. But a script calling this tool runs under `Sandbox`'s wall clock
  # and is handed that budget less a margin -- so a three-minute wait outlasted
  # its caller six times over, the sandbox killed the script, and
  # `AppTransport`'s `{:error, :restart_timed_out}` never reached the caller
  # (0b1ae6fc: the restart had in fact completed, and no one could tell).
  #
  # Derived from the sandbox rather than declared, so the number the tool waits
  # on always fits inside the script that calls it. Still used for the
  # synchronous (test-mode) path below, whose caller genuinely is bounded by
  # the sandbox -- the async path (issue f2977826, batch 2 of 4f7929e4) runs
  # in a detached task outside that clock entirely and no longer needs this
  # margin, which is why it declares its own, separate timeout instead.
  #
  # The margin must cover `AppTransport.call_grace_ms/0` too: `AppTransport`
  # adds that grace on top of whatever timeout it is given, so a margin
  # smaller than the grace lets the actual `GenServer.call` deadline land
  # past the sandbox's own kill time -- the exact failure 0b1ae6fc fixed,
  # reintroduced one layer down once the grace existed (4d727b2c).
  @machine_call_safety_ms 500

  @doc "How long this tool waits in the synchronous (test-mode) path -- never longer than the script that calls it."
  @spec declared_timeout() :: pos_integer()
  def declared_timeout do
    margin = AppInstances.call_grace_ms() + @machine_call_safety_ms
    max(Sandbox.timeout([]) - margin, 1_000)
  end

  defp timeout, do: declared_timeout()

  # Once genuinely async, the spawned task is outside the sandbox's wall
  # clock entirely -- this restores the real budget a restart (recompile +
  # boot) can need, the number this tool declared before 0b1ae6fc clipped it
  # down to fit a caller it no longer has to fit under.
  @async_call_timeout to_timeout(minute: 3)

  @impl true
  def name, do: "restart_app"

  @impl true
  def description do
    """
    Restart the caller's own copy of the app, on its current commit.

    By default this uses the caller's source checkout's default app instance.
    An explicit `instance_id` may select another harness instance from that same
    checkout, or Main may select one in a working copy it has explicitly connected
    to. The persisted Main identity and attachment are checked before dispatch.
    Provisioned deployments are not controlled by this tool. Omitting the ID never
    switches to an attachment. Detached Main must supply an ID.

    ## Returns when the run starts, not when it finishes

    A restart waits for a recompile and a boot, which can run well past the
    code-mode sandbox's 30s wall clock (issue f2977826, batch 2 of 4f7929e4)
    -- this used to shrink its own wait to fit that budget instead, racing it
    with a margin. The spawned task claims this working copy's own lock --
    shared with `stop_app` and `ensure_app_running`, since all three touch
    the same app process, and a restart racing another restart's own
    `_build` directory is exactly the hazard this closes -- and only then
    acks: the reply is "started" or "already running". A second restart_app
    call while one is in flight never starts a second one; it is told the
    one already running is still going. An agent that started it is messaged
    the outcome; any other caller calls this tool again to check.
    """
  end

  @impl true
  def params do
    %{
      instance_id: {:meta, :string, [description: "App instance UUID from `list_app_instances`."]}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} -> restart(scope, context, Map.get(params, :instance_id))
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp restart(scope, context, instance_id) do
    with {:ok, instance} <- Target.lifecycle(scope, context, instance_id) do
      starter = Starter.new(scope, context, "restart")
      scope |> start_restart_async(instance.id, starter) |> reply(context)
    else
      {:error, reason} -> {:error, Target.error(reason)}
    end
  end

  # `working_copies_app_run_async` -- `config/test.exs` pins it false, so
  # every existing test (including `app_tool_budget_test.exs`'s direct calls
  # to `declared_timeout/0`, which this flag does not touch) keeps running
  # this inline, bounded by `declared_timeout/0` as before.
  defp start_restart_async(scope, id, starter) do
    case Application.get_env(:code_my_spec, :working_copies_app_run_async, true) do
      true -> spawn_restart_async(scope, id, starter)
      _ -> AppRunLock.with_lock(id, fn -> do_restart(scope, id, timeout()) end)
    end
  end

  # Same handshake as `RunProvisioningStep.spawn_step_async/5`: the spawned
  # task claims `AppRunLock` first and only then signals, so the caller
  # learns "running" or "refused" in milliseconds, out of reach of this
  # call's own timeouts.
  defp spawn_restart_async(scope, id, starter) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        AppRunLock.with_lock(
          id,
          fn ->
            send(parent, {ref, :locked})
            do_restart(scope, id, @async_call_timeout)
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

  defp do_restart(scope, id, call_timeout) do
    case AppInstances.restart(scope, id, call_timeout) do
      {:ok, %{status: "serving", url: url, commit: commit}} ->
        instance = AppInstances.get!(scope, id)
        target_scope = %{scope | active_working_copy_id: instance.working_copy_id}
        Agents.record_app_restart(target_scope, "Restarted via RestartApp")
        {:ok, "Restarted -- serving #{commit || "unknown commit"} at #{url}."}

      {:ok, %{status: status, commit: commit}} ->
        {:error,
         "The app is #{status} (commit #{commit || "unknown"}) after restart. Not serving."}

      {:error, reason} ->
        {:error, "Could not restart the app: #{inspect(reason)}"}
    end
  end

  defp reply({:ok, :started}, context) do
    {:ok, "Restarting -- #{Starter.then_what(context[:agent_id])}"}
  end

  # The synchronous (test-mode) outcome: `do_restart/3`'s own result.
  defp reply({:ok, text}, _context), do: {:ok, text}

  defp reply({:error, {:already_running, started_at}}, _context) do
    since = started_at && " (started #{started_at})"

    {:error,
     "a restart is already in progress for this copy's app#{since} -- call this " <>
       "tool again to check, rather than starting another"}
  end

  defp reply({:error, :lock_handshake_timeout}, _context) do
    {:error, "could not confirm the restart started -- try again shortly"}
  end

  defp reply({:error, reason}, _context), do: {:error, reason}

  @doc false
  def outcome_message({:ok, text}), do: text
  def outcome_message({:error, reason}), do: reason

  defp refusal(:missing_active_project) do
    "This call names no project, so there is no working copy to restart an app for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."
end
