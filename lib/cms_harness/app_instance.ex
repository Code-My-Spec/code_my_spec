defmodule CmsHarness.AppInstance do
  @moduledoc """
  One working copy's own instance of the app it holds, on its own port and
  database, so a branch can be tested before it is promoted.

  Launch, track and kill follow `CodeMySpec.Workspaces.Runner.Local` (state in
  a JSON file, `kill -0` liveness, process-tree kill); a non-main copy's
  database is cloned from main's dev database. Lives under
  `CmsHarness.Copy.Supervisor` beside the channel chain, never in it: an app
  must survive a reconnect.

  Idle timeout: every reply re-arms it; `:timeout` stops the process
  (`restart: :temporary`). Activity is the app log's mtime, checked on a
  periodic tick — it also counts boots and migrations, which only delays a
  stop. Main's app is never stopped for idling.
  See knowledge/harness, "App instances".
  """

  use GenServer, restart: :temporary

  require Logger

  alias CmsHarness.AppInstance.LogTrim
  alias CmsHarness.AppInstance.Runner
  alias CmsHarness.Channel
  alias CmsHarness.Copy.Supervisor, as: Copy

  # Configurable so a test of the idle stop need not wait 30 minutes.
  defp idle_timeout,
    do: Application.get_env(:code_my_spec, :app_instance_idle_timeout_ms, to_timeout(minute: 30))

  defp log_max_bytes,
    do: Application.get_env(:code_my_spec, :app_instance_log_max_bytes, 50 * 1024 * 1024)

  defp idle_check_interval,
    do:
      Application.get_env(
        :code_my_spec,
        :app_instance_idle_check_interval_ms,
        to_timeout(minute: 2)
      )

  defstruct [
    :root,
    :port,
    :https_port,
    :database,
    :os_pid,
    # The commit the process launched from.
    :commit,
    # The commit the app serves now: `commit` after a launch, the reload's
    # commit after a reload.
    :serving_commit,
    :status,
    :log_path,
    :state_path,
    :tunnel_pid,
    :tunnel_id,
    # Monotonic deadline for a first start's background watch; `nil`
    # otherwise. Not persisted: it only drives an in-BEAM timer.
    :first_start_deadline,
    main?: false,
    tunnel_held_by_harness?: false
  ]

  # --- Client ---

  def start_link(root) when is_binary(root) do
    GenServer.start_link(__MODULE__, root, name: via(root))
  end

  def via(root), do: {:via, Registry, {CmsHarness.Registry, {:app_instance, root}}}

  @doc """
  Bring this copy's app up if it is not already running, and report its
  current state either way. Idempotent — the caller does not need to know
  whether anything was actually started.

  `main?: true` marks the project's designated copy (never idled out).
  `tunnel:` carries the tunnel credentials this copy should hold. Both are told
  fresh on every call, never remembered: only the server knows them and they
  can change while this process lives.

  `head` rides beside `commit`: the app restarts only on a promote, so a moved
  HEAD is not a stale report.
  """
  @spec ensure_running(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_running(root, opts \\ []) do
    with {:ok, pid} <- find_or_start(root),
         {:ok, info} <-
           GenServer.call(pid, {:ensure_running, main?(opts), tunnel(opts)}, op_timeout()) do
      info = Map.put(info, :head, Runner.current_commit(root))

      info =
        if info.status in ["down", "erroring"] do
          Map.put(
            info,
            :action_reason,
            "The health probe reports #{info.status}. Inspect the app log at #{log_path(root)} " <>
              "for startup or request errors. After correcting the cause, use restart_app " <>
              "to start this copy on its current HEAD."
          )
        else
          info
        end

      {:ok, info}
    end
  end

  @doc "Stop this copy's app, then start it again on the current commit."
  @spec restart(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restart(root, opts \\ []) do
    with {:ok, pid} <- find_or_start(root) do
      GenServer.call(pid, {:restart, main?(opts), tunnel(opts)}, op_timeout())
    end
  end

  @doc """
  Bring the running app current without restarting it: the project's
  `reload` recipe (migrate, let the code reloader compile, health-check), then
  the probe. On success the reply carries `action: "reloaded"` and the new
  `serving_commit`, and main runs its after-promote hook, as `restart/2` does.

  Restarts instead — `action: "restarted"`, `action_reason` saying why — when
  the app is not running or the project declares no `reload` recipe. A reload
  that fails replies an error and runs no hook: the caller restarts, and that
  restart runs it.
  """
  @spec reload(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reload(root, opts \\ []) do
    with {:ok, pid} <- find_or_start(root) do
      GenServer.call(pid, {:reload, main?(opts), tunnel(opts)}, reload_timeout())
    end
  end

  defp main?(opts), do: Keyword.get(opts, :main?, false)
  defp tunnel(opts), do: Keyword.get(opts, :tunnel)

  @doc """
  Bring this copy's tunnel connector up if it should hold one, without
  starting or touching the app itself.

  Called at join, which carries the tunnel so a harness restart does not leave
  the public preview down. The origin comes from `Runner.main_ports/1` (main's
  port is fixed by its `config/dev.exs`), since no `AppInstance` may be running
  yet. Idempotent: `Runner.start_tunnel/2` finds a running connector by id.
  """
  @spec ensure_tunnel_only(String.t(), map()) :: :ok
  def ensure_tunnel_only(root, tunnel) do
    case Runner.main_ports(root) do
      {http, _https} ->
        case Runner.start_tunnel(tunnel, "http://127.0.0.1:#{http}") do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[CmsHarness] could not start #{tunnel.hostname}'s tunnel at join: " <>
                "#{inspect(reason)}"
            )

            :ok
        end

      nil ->
        Logger.warning(
          "[CmsHarness] could not resolve #{root}'s own address; " <>
            "#{tunnel.hostname}'s tunnel was not started at join"
        )

        :ok
    end
  end

  @doc """
  Stop this copy's app. A copy with nothing running answers `:ok` too — there
  is nothing to stop, which is success, not a failure to report.
  """
  @spec stop_app(String.t()) :: :ok | {:error, term()}
  def stop_app(root) do
    # `find_or_start/1`, not a bare lookup: after a harness restart only
    # `init/1`'s read of the state file knows about a still-running app.
    with {:ok, pid} <- find_or_start(root) do
      GenServer.call(pid, :stop, op_timeout())
    end
  end

  @doc """
  Stop this copy's app and drop the database it was cloned into — offboarding,
  not idling. Both are this module's own disposable artifacts, never the
  checkout or main's database.
  """
  @spec discard(String.t()) :: :ok
  def discard(root) do
    with {:ok, pid} <- find_or_start(root) do
      GenServer.call(pid, :discard, op_timeout())
    end

    :ok
  end

  @doc "Note that this copy's app just did something — resets the idle clock."
  @spec touch(String.t()) :: :ok
  def touch(root) do
    case Registry.lookup(CmsHarness.Registry, {:app_instance, root}) do
      [{pid, _}] -> GenServer.cast(pid, :touch)
      [] -> :ok
    end
  end

  defp find_or_start(root) do
    case Registry.lookup(CmsHarness.Registry, {:app_instance, root}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        # Under its copy (`Copy.Supervisor`), beside the channel chain rather
        # than in it: an app must survive a reconnect.
        with {:ok, _copy} <- Copy.ensure(root) do
          case DynamicSupervisor.start_child(Copy.apps(root), {__MODULE__, root}) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp op_timeout, do: Application.get_env(:code_my_spec, :app_instance_op_timeout_ms, 120_000)

  # A reload may recompile the whole project.
  defp reload_timeout,
    do:
      Application.get_env(:code_my_spec, :app_instance_reload_timeout_ms, to_timeout(minute: 10))

  # --- Server ---

  @impl true
  def init(root) do
    state = %__MODULE__{
      root: root,
      log_path: log_path(root),
      state_path: state_path(root)
    }

    {:ok, restore_persisted(state), idle_timeout()}
  end

  @impl true
  def handle_call({:ensure_running, main?, tunnel}, _from, state) do
    state = %{state | main?: main?, tunnel_held_by_harness?: not is_nil(tunnel)}

    cond do
      running?(state) ->
        new_state = state |> probe() |> ensure_tunnel(main?, tunnel)
        {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}

      first_start?(state) ->
        start_first_run(state, main?, tunnel)

      true ->
        case start_app(state, tunnel, settle_by(op_timeout())) do
          {:ok, new_state} ->
            new_state = ensure_tunnel(new_state, main?, tunnel)
            {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}

          {:error, reason} ->
            new_state = ensure_tunnel(state, main?, tunnel)
            {:reply, {:error, reason}, new_state, idle_timeout()}
        end
    end
  end

  @impl true
  def handle_call({:restart, main?, tunnel}, from, state) do
    state = %{state | main?: main?, tunnel_held_by_harness?: not is_nil(tunnel)}
    restart_and_reply(state, from, main?, tunnel, %{}, settle_by(op_timeout()))
  end

  def handle_call({:reload, main?, tunnel}, from, state) do
    state = %{state | main?: main?, tunnel_held_by_harness?: not is_nil(tunnel)}

    cond do
      not running?(state) ->
        restart_instead(state, from, main?, tunnel, "the app was not running")

      not Runner.recipe?(state.root, "reload") ->
        restart_instead(state, from, main?, tunnel, "this project declares no reload recipe")

      true ->
        reload_in_place(state, from, main?, tunnel)
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    new_state = if running?(state), do: stop_process(state), else: state
    {:reply, :ok, new_state, idle_timeout()}
  end

  @impl true
  def handle_call(:discard, _from, state) do
    stopped = if running?(state), do: stop_process(state), else: state
    drop_database(stopped)
    {:stop, :normal, :ok, %{stopped | database: nil}}
  end

  @impl true
  def handle_cast(:touch, state), do: {:noreply, state, idle_timeout()}

  # A first start's background watch (see `start_first_run/3`). A stray check
  # after the deadline was cleared is ignored, never re-armed.
  @impl true
  def handle_info(:first_start_check, %__MODULE__{first_start_deadline: deadline} = state)
      when is_integer(deadline) do
    probed = probe(state)

    cond do
      probed.status == "serving" ->
        new_state = %{probed | first_start_deadline: nil}
        persist!(new_state)
        deliver_app_status(new_state)
        {:noreply, new_state, idle_timeout()}

      System.monotonic_time(:millisecond) >= deadline ->
        reason =
          "first start exceeded #{first_start_ceiling_minutes()} min; see #{state.log_path}"

        Logger.warning("[CmsHarness] #{state.root}: #{reason}")

        new_state = %{probed | status: "erroring", first_start_deadline: nil}
        persist!(new_state)
        deliver_app_status(new_state, reason)
        {:noreply, new_state, idle_timeout()}

      true ->
        # Still `starting`: `down`/`erroring` mid-compile is not a failure.
        new_state = %{probed | status: "starting"}
        persist!(new_state)
        schedule_first_start_check()
        {:noreply, new_state, idle_timeout()}
    end
  end

  def handle_info(:first_start_check, state), do: {:noreply, state, idle_timeout()}

  @impl true
  def handle_info(:timeout, %{main?: true} = state) do
    # Main's app is never stopped for idling — rule, not a longer timeout.
    Process.send_after(self(), :timeout, idle_check_interval())
    {:noreply, refresh_status(state), :infinity}
  end

  def handle_info(:timeout, state) do
    if running?(state) and recently_active?(state) do
      Process.send_after(self(), :timeout, idle_check_interval())
      {:noreply, refresh_status(state), :infinity}
    else
      new_state = if running?(state), do: stop_process(state), else: state
      {:stop, :normal, new_state}
    end
  end

  # Each tick re-probes a running app and reports a change, so an app that came
  # up after its health wait gave up does not stay "down".
  defp refresh_status(state) do
    LogTrim.trim(state.log_path, log_max_bytes())

    if running?(state) do
      probed = probe(state)
      if probed.status != state.status, do: deliver_app_status(probed)
      probed
    else
      state
    end
  end

  # --- Internals: restart and reload ---

  # `extra` rides on the success reply: empty for a plain restart, the
  # `action`/`action_reason` pair for a reload that restarted instead.
  defp restart_and_reply(state, from, main?, tunnel, extra, deadline) do
    stopped = if running?(state), do: stop_process(state), else: state

    case start_app(stopped, tunnel, deadline) do
      {:ok, new_state} ->
        new_state = ensure_tunnel(new_state, main?, tunnel)
        reply_then_hook(from, {:ok, Map.merge(result(new_state), extra)}, new_state, main?)

      {:error, reason} ->
        stopped = ensure_tunnel(stopped, main?, tunnel)
        {:reply, {:error, reason}, stopped, idle_timeout()}
    end
  end

  defp restart_instead(state, from, main?, tunnel, why) do
    Logger.info("[CmsHarness] reload of #{state.root}: restarting instead, #{why}")

    restart_and_reply(
      state,
      from,
      main?,
      tunnel,
      %{action: "restarted", action_reason: why},
      settle_by(reload_timeout())
    )
  end

  # The app stays up; the probe decides whether the reload took. A failure
  # runs no hook — the caller's restart will.
  defp reload_in_place(state, from, main?, tunnel) do
    Logger.info("[CmsHarness] reload of #{state.root}: running `just reload` on #{state.port}")

    case Runner.reload(state.root, state.port, state.https_port, state.database, state.log_path) do
      :ok ->
        state |> probe() |> reloaded(from, main?, tunnel)

      {:error, reason} ->
        Logger.warning("[CmsHarness] reload of #{state.root} failed: #{inspect(reason)}")
        {:reply, {:error, {:reload_failed, reason}}, state, idle_timeout()}
    end
  end

  defp reloaded(%__MODULE__{status: "serving"} = probed, from, main?, tunnel) do
    new_state = %{probed | serving_commit: current_commit(probed)}
    persist!(new_state)
    new_state = ensure_tunnel(new_state, main?, tunnel)

    Logger.info(
      "[CmsHarness] reload of #{new_state.root} done, serving #{new_state.serving_commit}"
    )

    reply_then_hook(
      from,
      {:ok, Map.put(result(new_state), :action, "reloaded")},
      new_state,
      main?
    )
  end

  defp reloaded(probed, _from, _main?, _tunnel) do
    Logger.warning(
      "[CmsHarness] reload of #{probed.root} ran, but the app answers #{probed.status}"
    )

    {:reply, {:error, {:reload_unhealthy, probed.status}}, probed, idle_timeout()}
  end

  # Main replies before the hook runs: an after-promote recipe may kill this
  # BEAM mid-run, so the reply must already be out.
  defp reply_then_hook(from, reply, new_state, true) do
    GenServer.reply(from, reply)
    after_promote(new_state)
    {:noreply, new_state, idle_timeout()}
  end

  defp reply_then_hook(_from, reply, new_state, false),
    do: {:reply, reply, new_state, idle_timeout()}

  # --- Internals: status ---

  @doc """
  The reply shape. Public so it can be tested without a real process.
  """
  def result(%__MODULE__{status: status, port: port, commit: commit} = state) do
    %{
      status: status || "down",
      url: url(port, status),
      commit: commit,
      serving_commit: state.serving_commit || commit
    }
  end

  @doc "A stopped copy never reports the address it used to answer on."
  def url(_port, status) when status in [nil, "down"], do: nil
  def url(port, _status), do: "http://127.0.0.1:#{port}"

  # Pushed unprompted when a background watch resolves a status nobody is
  # waiting on. Same keys an app verb's `_result` carries; `reason` is extra
  # and the server ignores it.
  defp deliver_app_status(state, reason \\ nil) do
    Channel.deliver_app_status(state.root, %{
      "status" => state.status,
      "url" => url(state.port, state.status),
      "commit" => state.commit,
      "reason" => reason
    })
  end

  # Alive and running in this copy's root: a persisted pid may have been
  # recycled, and a stop must never signal a stranger.
  defp running?(%__MODULE__{os_pid: nil}), do: false

  defp running?(%__MODULE__{os_pid: pid, root: root}) do
    Runner.alive?(pid) and Runner.process_root(pid) == Path.expand(root)
  end

  # The app log's mtime moving inside the idle window means "not idle".
  defp recently_active?(%__MODULE__{log_path: log_path}) do
    case File.stat(log_path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        System.os_time(:second) - mtime < idle_timeout() / 1000

      {:error, _} ->
        false
    end
  end

  defp probe(%__MODULE__{port: port} = state) when is_integer(port) do
    status = port |> Runner.probe() |> to_string()
    new_state = %{state | status: status}
    persist!(new_state)
    new_state
  end

  defp probe(state), do: state

  # --- Internals: start/stop ---

  defp start_app(state, tunnel, deadline) do
    with {:ok, launched_state} <- launch_process(state, tunnel) do
      {:ok, wait_for_health(launched_state, deadline)}
    end
  end

  # Shared by `start_app/3` and `start_first_run/3`: launch and persist, before
  # either decides how long to wait. A probe overwrites `"starting"` before any
  # reply is built.
  defp launch_process(state, tunnel) do
    with :ok <- ensure_serve_recipe(state),
         {:ok, {port, https_port, database}} <- ensure_port_and_database(state),
         :ok <- ensure_port_free(state, port),
         :ok <- ensure_database(state, database),
         {:ok, os_pid} <- launch(state, port, https_port, database, tunnel) do
      commit = current_commit(state)

      new_state = %{
        state
        | port: port,
          https_port: https_port,
          database: database,
          os_pid: os_pid,
          commit: commit,
          serving_commit: commit,
          status: "starting"
      }

      persist!(new_state)
      {:ok, new_state}
    end
  end

  # Never launched: `commit` is set by `launch_process/2` and survives a stop.
  # Only this case gets the backgrounded first start.
  defp first_start?(%__MODULE__{commit: nil}), do: true
  defp first_start?(_state), do: false

  # A cold first start (deps, assets, compile) can outrun the call timeout. So
  # it waits a short inline window, then replies `starting` with the address
  # and polls in the background up to `first_start_ceiling_ms/0`, pushing
  # `app_status` when it resolves.
  defp start_first_run(state, main?, tunnel) do
    case launch_process(state, tunnel) do
      {:ok, launched_state} ->
        window = first_start_probe_attempts() * health_wait_interval_ms()
        deadline = System.monotonic_time(:millisecond) + window
        settled_state = wait_for_health(launched_state, deadline)

        if settled_state.status == "serving" do
          new_state = ensure_tunnel(settled_state, main?, tunnel)
          {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}
        else
          # Reported as `starting`. `os_pid` is set, so a concurrent
          # `ensure_running` will not re-launch it.
          deadline = System.monotonic_time(:millisecond) + first_start_ceiling_ms()
          new_state = %{settled_state | status: "starting", first_start_deadline: deadline}
          persist!(new_state)
          schedule_first_start_check()
          {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}
        end

      {:error, reason} ->
        new_state = ensure_tunnel(state, main?, tunnel)
        {:reply, {:error, reason}, new_state, idle_timeout()}
    end
  end

  defp schedule_first_start_check,
    do: Process.send_after(self(), :first_start_check, health_wait_interval_ms())

  defp first_start_probe_attempts,
    do: Application.get_env(:code_my_spec, :app_instance_first_start_probe_attempts, 30)

  defp first_start_ceiling_ms,
    do:
      Application.get_env(
        :code_my_spec,
        :app_instance_first_start_ceiling_ms,
        to_timeout(minute: 10)
      )

  defp first_start_ceiling_minutes, do: div(first_start_ceiling_ms(), 60_000)

  defp ensure_serve_recipe(state) do
    if Runner.recipe?(state.root, "serve"), do: :ok, else: {:error, :no_start_recipe}
  end

  # The project's optional `after-promote` recipe: main only, and only after
  # a successful restart or reload. Its failure is only logged (the reply is
  # already out). The start line is flushed first, since the recipe may kill
  # this BEAM. See knowledge/harness, "App instances".
  defp after_promote(state) do
    if Runner.recipe?(state.root, "after-promote") do
      run_after_promote(state.root)
    else
      :ok
    end
  end

  defp run_after_promote(root) do
    Logger.info(
      "[CmsHarness] after-promote: running `just after-promote` in #{root}. " <>
        "If it restarts the harness, no done line follows; the next boot line confirms it."
    )

    sync_log_files()
    started = System.monotonic_time(:millisecond)
    result = Runner.run_after_promote(root)
    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      :ok ->
        Logger.info("[CmsHarness] after-promote done in #{root}: exit 0 in #{elapsed}ms")

      {:error, reason} ->
        Logger.warning(
          "[CmsHarness] after-promote failed in #{root} after #{elapsed}ms: #{inspect(reason)}. " <>
            "The app is serving; only the hook failed."
        )
    end

    result
  end

  # `:logger_std_h` buffers writes (`delayed_write`, up to 2s); a kill inside
  # that window loses the line. `filesync/1` is a call, so it lands after the
  # event this process just logged.
  defp sync_log_files do
    for %{id: id, module: :logger_std_h} <- :logger.get_handler_config() do
      :logger_std_h.filesync(id)
    end

    :ok
  end

  # Reused across restarts once allocated: a stable address. `https_port` is
  # always allocated; unset, an app falls back to its config default and
  # collides with main's.
  defp ensure_port_and_database(%__MODULE__{
         port: port,
         https_port: https_port,
         database: database
       })
       when is_integer(port) and is_integer(https_port) and is_binary(database) do
    {:ok, {port, https_port, database}}
  end

  # Main keeps its own address and real dev database, both from its
  # `config/dev.exs`.
  defp ensure_port_and_database(%__MODULE__{main?: true} = state) do
    with {http, https} <- Runner.main_ports(state.root),
         database when is_binary(database) <- Runner.main_database_name(state.root) do
      {:ok, {state.port || http, state.https_port || https, state.database || database}}
    else
      _ -> {:error, {:cannot_resolve_main_address, state.root}}
    end
  end

  defp ensure_port_and_database(state) do
    {:ok,
     {state.port || Runner.free_port(), state.https_port || Runner.free_port(),
      state.database || database_name(state)}}
  end

  # Main's fixed port may be held by an untracked server. Killed only when its
  # cwd is this checkout's root; anything else is refused, never killed.
  # Non-main ports come fresh from `free_port/0`.
  defp ensure_port_free(%__MODULE__{main?: true} = state, port) do
    case Runner.listener_pid(port) do
      nil ->
        :ok

      pid ->
        if Runner.process_root(pid) == Path.expand(state.root) do
          Runner.stop_process(pid)
          :ok
        else
          {:error, {:port_held_by_untracked_process, port, pid}}
        end
    end
  end

  defp ensure_port_free(_state, _port), do: :ok

  # `<app>_dev_wc_<hash of root>`: stable per checkout, distinct across copies.
  defp database_name(state) do
    app = Runner.app_name(state.root) || "app"

    suffix =
      state.root
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "#{app}_dev_wc_#{suffix}"
  end

  # Drops only names in this module's own `_dev_wc_` convention: no undo.
  defp drop_database(%__MODULE__{database: database})
       when is_binary(database) do
    if safe_identifier?(database) and String.contains?(database, "_dev_wc_") do
      Runner.drop_database(database)
    end

    :ok
  end

  defp drop_database(_state), do: :ok

  defp ensure_database(state, database) do
    if Runner.database_exists?(database), do: :ok, else: clone_database(state, database)
  end

  defp clone_database(state, database) do
    main_db = Runner.main_database_name(state.root)

    cond do
      not (is_binary(main_db) and safe_identifier?(main_db)) ->
        {:error, {:cannot_resolve_main_database, main_db}}

      not safe_identifier?(database) ->
        {:error, {:unsafe_database_name, database}}

      true ->
        with :ok <- Runner.clone_database(state.root, main_db, database) do
          Runner.seed(state.root)
          :ok
        end
    end
  end

  @doc """
  Whether `name` is safe to interpolate into the shell string
  `CmsHarness.AppInstance.Runner.Local.clone_database/3` builds. Public so it
  is tested.
  """
  def safe_identifier?(name), do: is_binary(name) and Regex.match?(~r/^[a-zA-Z0-9_]+$/, name)

  defp current_commit(state), do: Runner.current_commit(state.root)

  defp launch(state, port, https_port, database, tunnel) do
    Runner.launch(
      state.root,
      port,
      https_port,
      database,
      state.log_path,
      state.main?,
      state.tunnel_held_by_harness?,
      tunnel_host(tunnel)
    )
  end

  # A booting app needs the hostname to answer `Endpoint.url()` correctly.
  defp tunnel_host(%{hostname: hostname}), do: hostname
  defp tunnel_host(_), do: nil

  # Until the app serves, its process exits, or `deadline` passes; the reply is
  # the last probe. `erroring` does not end the wait: a booting app answers it
  # before its assets are built.
  defp wait_for_health(state, deadline) do
    probed = probe(state)

    cond do
      probed.status == "serving" ->
        probed

      not Runner.alive?(state.os_pid) ->
        probed

      System.monotonic_time(:millisecond) >= deadline ->
        probed

      true ->
        Process.sleep(health_wait_interval_ms())
        wait_for_health(state, deadline)
    end
  end

  # A start replies inside the call that asked for it, so it settles by three
  # quarters of that call's timeout: the rest covers the stop and the launch.
  defp settle_by(call_timeout), do: System.monotonic_time(:millisecond) + div(call_timeout * 3, 4)

  defp health_wait_interval_ms,
    do: Application.get_env(:code_my_spec, :app_instance_health_wait_interval_ms, 1_000)

  defp stop_process(%__MODULE__{os_pid: pid} = state) when is_integer(pid) do
    Runner.stop_process(pid)

    # A stopped copy never keeps a stale address.
    new_state = %{state | status: "down"}
    persist!(new_state)
    new_state
  end

  defp stop_process(state), do: %{state | status: "down"}

  # --- Internals: tunnel ---
  #
  # The harness holds the tunnel, not the app, so an app restart keeps the
  # connector. Whether to hold one is decided by whether one was handed over,
  # never by main-ness; copies handed the same tunnel share one connector.
  # Handed none: nothing to run and nothing stopped (a shared connector carries
  # other copies' addresses). See knowledge/harness, "App instances".
  defp ensure_tunnel(state, _main?, nil), do: state

  # Already running this tunnel: re-checked each call, since an unlinked
  # connector can die on its own.
  defp ensure_tunnel(
         %__MODULE__{tunnel_pid: pid, tunnel_id: id} = state,
         _main?,
         %{tunnel_id: id} = tunnel
       )
       when is_pid(pid) do
    if Process.alive?(pid),
      do: state,
      else: start_tunnel(%{state | tunnel_pid: nil, tunnel_id: nil}, tunnel)
  end

  # Holding a tunnel for different credentials: swap to the new ones.
  defp ensure_tunnel(%__MODULE__{tunnel_pid: pid} = state, _main?, tunnel) when is_pid(pid) do
    Runner.stop_tunnel(pid)
    start_tunnel(%{state | tunnel_pid: nil, tunnel_id: nil}, tunnel)
  end

  defp ensure_tunnel(state, _main?, tunnel), do: start_tunnel(state, tunnel)

  defp start_tunnel(state, tunnel) do
    case tunnel_origin(state) do
      nil ->
        Logger.warning(
          "[CmsHarness] could not resolve this copy's own port; " <>
            "#{tunnel.hostname}'s tunnel was not started"
        )

        state

      origin ->
        case Runner.start_tunnel(tunnel, origin) do
          {:ok, pid} ->
            %{state | tunnel_pid: pid, tunnel_id: tunnel.tunnel_id}

          {:error, reason} ->
            Logger.warning(
              "[CmsHarness] could not start #{tunnel.hostname}'s tunnel: #{inspect(reason)}. " <>
                "The app is unaffected; only the public address is not reachable."
            )

            state
        end
    end
  end

  # The persisted port, else main's fixed port from `config/dev.exs` (reached
  # when the app's own start failed).
  defp tunnel_origin(%__MODULE__{port: port}) when is_integer(port),
    do: "http://127.0.0.1:#{port}"

  defp tunnel_origin(%__MODULE__{root: root}) do
    case Runner.main_ports(root) do
      {http, _https} -> "http://127.0.0.1:#{http}"
      _ -> nil
    end
  end

  # --- Internals: persistence ---

  defp persist!(state) do
    File.mkdir_p!(Path.dirname(state.state_path))

    payload = %{
      "port" => state.port,
      "https_port" => state.https_port,
      "database" => state.database,
      "os_pid" => state.os_pid,
      "commit" => state.commit,
      "serving_commit" => state.serving_commit,
      "status" => state.status
    }

    File.write!(state.state_path, Jason.encode!(payload))
  end

  defp restore_persisted(state) do
    case File.read(state.state_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = decoded} -> apply_persisted(state, decoded)
          _ -> state
        end

      {:error, _} ->
        state
    end
  end

  defp apply_persisted(state, decoded) do
    %{
      state
      | port: decoded["port"],
        https_port: decoded["https_port"],
        database: decoded["database"],
        os_pid: decoded["os_pid"],
        commit: decoded["commit"],
        serving_commit: decoded["serving_commit"],
        status: decoded["status"]
    }
  end

  @doc """
  What this copy's app is, read from the harness's own `state.json`.

  The durable answer to "which commit is running here", sent on join so the
  server converges even if a reply was lost to a harness restart. Read from
  disk because no `AppInstance` may be running yet. `nil` when nothing was ever
  written.
  """
  @spec reported(String.t()) :: map() | nil
  def reported(root) when is_binary(root) do
    case File.read(state_path(root)) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = decoded} ->
            %{
              "status" => decoded["status"] || "down",
              "commit" => decoded["commit"],
              "serving_commit" => decoded["serving_commit"],
              "url" => url(decoded["port"], decoded["status"])
            }

          _ ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp state_path(root) do
    Path.join([instances_root(), instance_key(root), "state.json"])
  end

  defp log_path(root) do
    Path.join([instances_root(), instance_key(root), "app.log"])
  end

  defp instance_key(root) do
    :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp instances_root do
    Application.get_env(
      :code_my_spec,
      :app_instances_root,
      Path.expand("~/.codemyspec/app-instances")
    )
  end
end
