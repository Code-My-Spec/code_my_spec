defmodule CodeMySpec.AppInstances.Tools.EnsureAppRunning do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.CodeMode.Sandbox
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.AppInstances
  alias CodeMySpec.AppInstances.AppRunLock
  alias CodeMySpec.AppInstances.Tools.Starter
  alias CodeMySpec.AppInstances.Tools.Target

  # A first boot compiles, which is why this was once three minutes. But a
  # script calling this tool runs under `Sandbox`'s wall clock and is handed
  # that budget less a margin, so a three-minute wait outlasted its caller,
  # the sandbox killed the script, and the caller never saw `AppTransport`'s
  # `:start_timed_out` (0b1ae6fc). Derived from the sandbox rather than
  # declared, so the wait always fits inside the script. Still used for the
  # synchronous (test-mode) path below -- the async path (issue f2977826,
  # batch 2 of 4f7929e4) runs in a detached task outside that clock entirely.
  #
  # The margin must cover `Transport.call_grace_ms/0` too: `AppTransport`
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
  # clock entirely -- this restores the real budget a first boot's compile
  # can need, the number this tool declared before 0b1ae6fc clipped it down
  # to fit a caller it no longer has to fit under.
  @async_call_timeout to_timeout(minute: 3)

  @impl true
  def name, do: "ensure_app_running"

  @impl true
  def description do
    """
    Bring up the caller's own copy of the app, starting it if it isn't already
    running. A live process is health-checked, not automatically restarted when
    HEAD moves. If it is unhealthy, the error reports the current checkout HEAD,
    the last recorded app revision, and the app log to inspect before recovery.
    A healthy app whose served revision differs from HEAD, or whose revision
    cannot be verified, returns an error refusing QA against it. The process
    stays running; restart_app refreshes it explicitly.

    By default this uses the caller's source checkout's default app instance.
    An explicit `instance_id` may select another harness instance from that same
    checkout, or Main may select one in a working copy it has explicitly connected
    to. The persisted Main identity and attachment are checked before dispatch.
    Provisioned deployments are not controlled by this tool. Omitting the ID never
    switches to an attachment. Detached Main must supply an ID.

    ## Returns when the run starts, not when it finishes

    A first boot compiles, which can run well past the code-mode sandbox's
    30s wall clock (issue f2977826, batch 2 of 4f7929e4) -- this used to
    shrink its own wait to fit that budget instead, racing it with a margin.
    The spawned task claims this working copy's own lock -- shared with
    `restart_app` and `stop_app`, since all three touch the same app process
    -- and only then acks: the reply is "started" or "already running"; an
    agent that started it is messaged the outcome, any other caller calls
    this tool again to check.
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
      {:ok, scope} -> ensure_running(scope, context, Map.get(params, :instance_id))
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp ensure_running(scope, context, instance_id) do
    with {:ok, instance} <- Target.lifecycle(scope, context, instance_id) do
      starter = Starter.new(scope, context, "start")
      instance.id |> start_ensure_async(starter, scope) |> reply(context)
    else
      {:error, reason} -> {:error, Target.error(reason)}
    end
  end

  # `working_copies_app_run_async` -- `config/test.exs` pins it false, so
  # every existing test keeps running this inline, bounded by
  # `declared_timeout/0` as before.
  defp start_ensure_async(id, starter, scope) do
    case Application.get_env(:code_my_spec, :working_copies_app_run_async, true) do
      true -> spawn_ensure_async(id, starter, scope)
      _ -> AppRunLock.with_lock(id, fn -> do_ensure_running(scope, id, timeout()) end)
    end
  end

  # Same handshake as `RunProvisioningStep.spawn_step_async/5`: the spawned
  # task claims `AppRunLock` first and only then signals, so the caller
  # learns "running" or "refused" in milliseconds, out of reach of this
  # call's own timeouts.
  defp spawn_ensure_async(id, starter, scope) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        AppRunLock.with_lock(
          id,
          fn ->
            send(parent, {ref, :locked})
            do_ensure_running(scope, id, @async_call_timeout)
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

  defp do_ensure_running(scope, id, call_timeout) do
    case AppInstances.ensure_running(scope, id, call_timeout) do
      {:ok, %{status: "serving", url: url, commit: commit} = info} ->
        serving = Map.get(info, :serving_commit) || commit

        case AppInstances.qa_revision_check(info) do
          :ok ->
            {:ok, "#{copy_name(scope, id)} app is serving #{serving} at #{url}."}

          {:error, reason} ->
            {:error,
             "#{copy_name(scope, id)} app is running but is not verified for QA. " <> reason}
        end

      # A first start that outlasted its inline window: booting, not failed.
      {:ok, %{status: "starting", url: url, commit: commit}} ->
        {:ok,
         "#{copy_name(scope, id)} app is starting #{commit || "unknown commit"} at #{url}. " <>
           "Its first boot is still compiling; call ensure_app_running again to see it serving."}

      {:ok, %{status: status, commit: commit} = info} ->
        not_serving(scope, id, status, commit, info)

      {:error, reason} ->
        {:error, "Could not start the app: #{inspect(reason)}"}
    end
  end

  defp reply({:ok, :started}, context) do
    {:ok, "Starting -- #{Starter.then_what(context[:agent_id])}"}
  end

  # The synchronous (test-mode) outcome: `do_ensure_running/2`'s own result.
  defp reply({:ok, text}, _context), do: {:ok, text}

  defp reply({:error, {:already_running, started_at}}, _context) do
    since = started_at && " (started #{started_at})"

    {:error,
     "a run is already in progress for this copy's app#{since} -- call this " <>
       "tool again to check, rather than starting another"}
  end

  defp reply({:error, :lock_handshake_timeout}, _context) do
    {:error, "could not confirm starting the app -- try again shortly"}
  end

  defp reply({:error, reason}, _context), do: {:error, reason}

  @doc false
  def outcome_message({:ok, text}), do: text
  def outcome_message({:error, reason}), do: reason

  # 048d1f4f: an agent read its own copy's app as main's, and a launch commit
  # behind HEAD as a restart that failed. Always say whose app this is, and
  # when HEAD has moved past what it serves.
  defp not_serving(scope, id, status, commit, info) do
    last_commit = Map.get(info, :serving_commit) || commit
    head = Map.get(info, :head) || "unknown"

    reason =
      Map.get(info, :action_reason) ||
        "The harness supplied no startup diagnostics. Inspect this copy's app log before using restart_app."

    {:error,
     "#{copy_name(scope, id)} app is #{status}. Not serving. " <>
       "Last recorded app revision: #{last_commit || "unknown"}; current checkout HEAD: #{head}. " <>
       reason}
  end

  defp copy_name(scope, id) do
    case AppInstances.get(scope, id) do
      nil ->
        "Your"

      %{working_copy_id: copy_id} ->
        copy_label(WorkingCopies.fetch(copy_id), scope.active_working_copy_id)
    end
  end

  defp refusal(:missing_active_project) do
    "This call names no project, so there is no working copy to start an app for."
  end

  defp refusal(reason), do: "This call has no usable project scope (#{inspect(reason)})."

  defp copy_label({:ok, %{main: true} = copy}, _own_id),
    do: "Main copy #{copy.root || copy.label}'s"

  defp copy_label({:ok, %{id: id} = copy}, id),
    do: "Your copy #{copy.root || copy.label}'s (not main's)"

  defp copy_label({:ok, copy}, _own_id), do: "Selected copy #{copy.root || copy.label}'s"
  defp copy_label({:error, _}, _own_id), do: "Your copy's"
end
