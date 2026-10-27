defmodule CmsHarness.AppInstance do
  @moduledoc """
  An independently identified app runtime with an explicit source checkout.

  Registry, state, logs and cloned database identities use the instance UUID.
  The harness-wide supervisor preserves runtimes through copy channel restarts.
  Descriptor policies control idling, ports, databases and promotion hooks.
  """

  use GenServer, restart: :temporary

  require Logger

  alias CmsHarness.AppInstance.Runner
  alias CmsHarness.Channel

  # Configurable so a test of the idle stop need not wait 30 minutes.
  defp idle_timeout,
    do: Application.get_env(:code_my_spec, :app_instance_idle_timeout_ms, to_timeout(minute: 30))

  defp idle_check_interval,
    do:
      Application.get_env(
        :code_my_spec,
        :app_instance_idle_check_interval_ms,
        to_timeout(minute: 2)
      )

  defstruct [
    :instance_id,
    :working_copy_id,
    :root,
    :database_source,
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
    # Monotonic deadline for a slow start's background watch; `nil`
    # otherwise. Not persisted: it only drives an in-BEAM timer.
    :first_start_deadline,
    # Which start is being watched ("first start", "restart"), for the reason
    # given when its ceiling passes.
    :slow_start,
    # The HEAD a moved copy was last brought onto, tried once whatever came
    # of it, so a failing reload is not retried on every idle check.
    :brought_to,
    default: false,
    persistent: false,
    port_mode: "allocated",
    database_mode: "clone",
    after_promote: false,
    tunnel_held_by_harness?: false
  ]

  # --- Client ---

  def start_link(descriptor) when is_map(descriptor) do
    with {:ok, descriptor} <- validate_descriptor(descriptor) do
      GenServer.start_link(__MODULE__, descriptor, name: via(descriptor))
    end
  end

  def via(%{"instance_id" => id}), do: via(id)
  def via(id), do: {:via, Registry, {CmsHarness.Registry, {:app_instance, id}}}

  def validate_descriptor(%{"instance_id" => id, "root" => root} = descriptor)
      when is_binary(root) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         true <- descriptor["port_mode"] in ["configured", "allocated"],
         true <- descriptor["database_mode"] in ["configured", "clone"],
         true <- is_boolean(Map.get(descriptor, "default", false)),
         true <- is_boolean(descriptor["persistent"]),
         true <- is_boolean(descriptor["after_promote"]) do
      {:ok,
       descriptor
       |> Map.put("root", CodeMySpec.Paths.expand(root))
       |> Map.put_new("default", false)}
    else
      _ -> {:error, :invalid_instance_descriptor}
    end
  end

  def validate_descriptor(_), do: {:error, :invalid_instance_descriptor}

  @doc """
  Bring this copy's app up if it is not already running, and report its
  current state either way. Idempotent — the caller does not need to know
  whether anything was actually started.

  The descriptor supplies independent persistence, port, database and hook
  policies. `tunnel:` carries the connector credentials. These are refreshed
  on each call from the authenticated server channel.

  `head` rides beside `commit`: the app restarts only on a promote, so a moved
  HEAD is not a stale report.
  """
  @spec ensure_running(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_running(descriptor, opts \\ []) do
    with {:ok, pid} <- find_or_start(descriptor),
         {:ok, info} <-
           GenServer.call(
             pid,
             {:ensure_running, descriptor["after_promote"], tunnel(opts)},
             op_timeout()
           ) do
      info = Map.put(info, :head, Runner.current_commit(descriptor["root"]))

      info =
        if info.status in ["down", "erroring"] do
          Map.put(
            info,
            :action_reason,
            "The health probe reports #{info.status}. Inspect the app log at #{log_path(descriptor)} " <>
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
  @spec restart(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def restart(descriptor, opts \\ []) do
    with {:ok, pid} <- find_or_start(descriptor) do
      GenServer.call(pid, {:restart, descriptor["after_promote"], tunnel(opts)}, op_timeout())
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
  @spec reload(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reload(descriptor, opts \\ []) do
    with {:ok, pid} <- find_or_start(descriptor) do
      GenServer.call(pid, {:reload, descriptor["after_promote"], tunnel(opts)}, reload_timeout())
    end
  end

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
  @spec stop_app(map()) :: :ok | {:error, term()}
  def stop_app(descriptor) do
    # `find_or_start/1`, not a bare lookup: after a harness restart only
    # `init/1`'s read of the state file knows about a still-running app.
    with {:ok, pid} <- find_or_start(descriptor) do
      GenServer.call(pid, :stop, op_timeout())
    end
  end

  @doc """
  Stop this copy's app and drop the database it was cloned into — offboarding,
  not idling. Both are this module's own disposable artifacts, never the
  checkout or main's database.
  """
  @spec discard(map()) :: :ok | {:error, term()}
  def discard(descriptor) do
    with {:ok, pid} <- find_or_start(descriptor) do
      GenServer.call(pid, :discard, op_timeout())
    end
  end

  @doc "Note that this copy's app just did something — resets the idle clock."
  @spec touch(map()) :: :ok
  def touch(%{"instance_id" => id}) do
    case Registry.lookup(CmsHarness.Registry, {:app_instance, id}) do
      [{pid, _}] -> GenServer.cast(pid, :touch)
      [] -> :ok
    end
  end

  defp find_or_start(descriptor) do
    with {:ok, descriptor} <- validate_descriptor(descriptor) do
      case Registry.lookup(CmsHarness.Registry, {:app_instance, descriptor["instance_id"]}) do
        [{pid, _}] ->
          validate_existing(pid, descriptor)

        [] ->
          case DynamicSupervisor.start_child(
                 CmsHarness.AppInstancesSupervisor,
                 {__MODULE__, descriptor}
               ) do
            {:ok, pid} -> validate_existing(pid, descriptor)
            {:error, {:already_started, pid}} -> validate_existing(pid, descriptor)
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp validate_existing(pid, descriptor) do
    case GenServer.call(pid, {:validate_source, descriptor}, max(op_timeout(), reload_timeout())) do
      :ok -> {:ok, pid}
      error -> error
    end
  end

  defp op_timeout, do: Application.get_env(:code_my_spec, :app_instance_op_timeout_ms, 120_000)

  # A reload may recompile the whole project.
  defp reload_timeout,
    do:
      Application.get_env(:code_my_spec, :app_instance_reload_timeout_ms, to_timeout(minute: 10))

  # --- Server ---

  @impl true
  def init(descriptor) do
    case validate_persisted_descriptor(descriptor) do
      :ok -> init_instance(descriptor)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_instance(descriptor) do
    state = %__MODULE__{
      instance_id: descriptor["instance_id"],
      working_copy_id: descriptor["working_copy_id"],
      root: descriptor["root"],
      default: descriptor["default"],
      persistent: descriptor["persistent"],
      port_mode: descriptor["port_mode"],
      database_mode: descriptor["database_mode"],
      database_source: descriptor["database_source"],
      after_promote: descriptor["after_promote"],
      log_path: log_path(descriptor),
      state_path: state_path(descriptor)
    }

    state = state |> import_legacy() |> restore_persisted()
    persist!(state)
    {:ok, state, idle_timeout()}
  end

  defp validate_persisted_descriptor(descriptor) do
    with {:ok, data} <- File.read(state_path(descriptor)),
         {:ok, persisted} <- Jason.decode(data),
         true <-
           persisted["instance_id"] == descriptor["instance_id"] and
             persisted["root"] == descriptor["root"] and
             persisted["working_copy_id"] == descriptor["working_copy_id"] do
      validate_storage_policy(persisted, descriptor)
    else
      {:error, :enoent} -> :ok
      _ -> {:error, :instance_source_mismatch}
    end
  end

  defp validate_storage_policy(persisted, descriptor) do
    allocated? = not is_nil(persisted["port"]) or not is_nil(persisted["database"])

    matches? =
      Enum.all?(
        ~w(port_mode database_mode database_source),
        fn key -> persisted[key] == descriptor[key] end
      )

    if not allocated? or matches?, do: :ok, else: {:error, :instance_storage_policy_mismatch}
  end

  @impl true
  def handle_call({:validate_source, descriptor}, _from, state) do
    reply =
      if state.root == descriptor["root"] and
           state.working_copy_id == descriptor["working_copy_id"],
         do:
           validate_storage_policy(
             %{
               "port" => state.port,
               "database" => state.database,
               "port_mode" => state.port_mode,
               "database_mode" => state.database_mode,
               "database_source" => state.database_source
             },
             descriptor
           ),
         else: {:error, :instance_source_mismatch}

    state =
      if reply == :ok do
        %{
          state
          | default: descriptor["default"],
            persistent: descriptor["persistent"],
            port_mode: descriptor["port_mode"],
            database_mode: descriptor["database_mode"],
            database_source: descriptor["database_source"],
            after_promote: descriptor["after_promote"]
        }
      else
        state
      end

    {:reply, reply, state, idle_timeout()}
  end

  @impl true
  def handle_call({:ensure_running, after_promote?, tunnel}, _from, state) do
    state = %{state | after_promote: after_promote?, tunnel_held_by_harness?: not is_nil(tunnel)}

    cond do
      running?(state) ->
        new_state = state |> probe() |> ensure_tunnel(after_promote?, tunnel)
        {:reply, {:ok, catching_up(new_state)}, new_state, idle_timeout()}

      first_start?(state) ->
        start_first_run(state, after_promote?, tunnel)

      true ->
        case start_app(state, tunnel, settle_by(op_timeout())) do
          {:ok, new_state} ->
            new_state = ensure_tunnel(new_state, after_promote?, tunnel)
            {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}

          {:error, reason} ->
            new_state = ensure_tunnel(state, after_promote?, tunnel)
            {:reply, {:error, reason}, new_state, idle_timeout()}
        end
    end
  end

  @impl true
  def handle_call({:restart, after_promote?, tunnel}, from, state) do
    state = %{state | after_promote: after_promote?, tunnel_held_by_harness?: not is_nil(tunnel)}
    restart_and_reply(state, from, after_promote?, tunnel, %{}, settle_by(op_timeout()))
  end

  def handle_call({:reload, after_promote?, tunnel}, from, state) do
    state = %{state | after_promote: after_promote?, tunnel_held_by_harness?: not is_nil(tunnel)}

    cond do
      not running?(state) ->
        restart_instead(state, from, after_promote?, tunnel, "the app was not running")

      not Runner.recipe?(state.root, "reload") ->
        restart_instead(
          state,
          from,
          after_promote?,
          tunnel,
          "this project declares no reload recipe"
        )

      reloader_cannot_take?(state) ->
        restart_instead(
          state,
          from,
          after_promote?,
          tunnel,
          "mix.lock, mix.exs or config changed, which the code reloader cannot pick up"
        )

      true ->
        reload_in_place(state, from, after_promote?, tunnel)
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    case stop_if_running(state) do
      {:ok, new_state} -> {:reply, :ok, new_state, idle_timeout()}
      {:error, reason} -> {:reply, {:error, reason}, state, idle_timeout()}
    end
  end

  @impl true
  def handle_call(:discard, _from, state) do
    case stop_if_running(state) do
      {:ok, stopped} ->
        with :ok <- drop_database(stopped),
             :ok <- clear_database_name_status(stopped),
             :ok <- retire_legacy_claim(stopped),
             :ok <- File.rm(stopped.state_path) do
          {:stop, :normal, :ok, %{stopped | database: nil}}
        else
          {:error, reason} -> {:reply, {:error, reason}, stopped, idle_timeout()}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state, idle_timeout()}
    end
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
          "#{state.slow_start} exceeded #{first_start_ceiling_minutes()} min; see #{state.log_path}"

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

  # The reload `catching_up/1` asked for, run as the reload a promote asks for,
  # with this process as the caller; its answer arrives as `:bring_current_reply`.
  def handle_info(:bring_current, state) do
    if head_moved?(state) do
      {:reload, state.after_promote, nil}
      |> handle_call({self(), :bring_current_reply}, %{state | brought_to: current_commit(state)})
      |> as_noreply()
    else
      {:noreply, state, idle_timeout()}
    end
  end

  def handle_info({:bring_current_reply, {:ok, info}}, state) do
    Logger.info("[CmsHarness] #{state.root} brought current: #{info.status} at #{info.commit}")
    {:noreply, state, idle_timeout()}
  end

  def handle_info({:bring_current_reply, {:error, reason}}, state) do
    Logger.warning("[CmsHarness] could not bring #{state.root} current: #{inspect(reason)}")
    {:noreply, state, idle_timeout()}
  end

  @impl true
  def handle_info(:timeout, %{persistent: true} = state) do
    # Main's app is never stopped for idling — rule, not a longer timeout.
    Process.send_after(self(), :timeout, idle_check_interval())
    {:noreply, refresh_status(state), :infinity}
  end

  def handle_info(:timeout, state) do
    if running?(state) and recently_active?(state) do
      Process.send_after(self(), :timeout, idle_check_interval())
      state = refresh_status(state)
      _ = catching_up(state)
      {:noreply, state, :infinity}
    else
      # Stops the app, not this process: one exiting here stays registered until
      # it is gone, so a request landing in between got no reply. The next
      # `ensure_running` starts the app again.
      case stop_if_running(state) do
        {:ok, new_state} ->
          {:noreply, new_state, :hibernate}

        {:error, reason} ->
          Logger.warning(
            "[CmsHarness] could not stop idle instance #{state.instance_id}: #{inspect(reason)}"
          )

          {:noreply, state, idle_check_interval()}
      end
    end
  end

  # Each tick re-probes a running app and reports a change, so an app that came
  # up after its health wait gave up does not stay "down".
  defp refresh_status(state) do
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
  defp restart_and_reply(state, from, after_promote?, tunnel, extra, deadline) do
    case stop_if_running(state) do
      {:ok, stopped} -> start_and_reply(stopped, from, after_promote?, tunnel, extra, deadline)
      {:error, reason} -> {:reply, {:error, reason}, state, idle_timeout()}
    end
  end

  defp start_and_reply(stopped, from, after_promote?, tunnel, extra, deadline) do
    case start_app(stopped, tunnel, deadline) do
      {:ok, new_state} ->
        new_state =
          new_state |> watch_if_booting("restart") |> ensure_tunnel(after_promote?, tunnel)

        reply_then_hook(
          from,
          {:ok, Map.merge(result(new_state), extra)},
          new_state,
          after_promote?
        )

      {:error, reason} ->
        stopped = ensure_tunnel(stopped, after_promote?, tunnel)
        {:reply, {:error, reason}, stopped, idle_timeout()}
    end
  end

  defp restart_instead(state, from, after_promote?, tunnel, why) do
    Logger.info("[CmsHarness] reload of #{state.root}: restarting instead, #{why}")

    restart_and_reply(
      state,
      from,
      after_promote?,
      tunnel,
      %{action: "restarted", action_reason: why},
      settle_by(reload_timeout())
    )
  end

  # The app stays up; the probe decides whether the reload took. A failure
  # runs no hook — the caller's restart will. Unless the app is down: then the
  # caller may be that app (:4000 reloading itself), and nobody would restart
  # it — it sat down from 02:15 to 02:19 on 2026-10-16. It is restarted here.
  defp reload_in_place(state, from, after_promote?, tunnel) do
    Logger.info("[CmsHarness] reload of #{state.root}: running `just reload` on #{state.port}")

    case Runner.reload(state.root, state.port, state.https_port, state.database, state.log_path) do
      :ok ->
        state |> probe() |> reloaded(from, after_promote?, tunnel)

      {:error, reason} ->
        Logger.warning("[CmsHarness] reload of #{state.root} failed: #{inspect(reason)}")

        case probe(state) do
          %{status: "down"} = down ->
            restart_instead(
              down,
              from,
              after_promote?,
              tunnel,
              "the reload failed and left the app down"
            )

          probed ->
            {:reply, {:error, {:reload_failed, reason}}, probed, idle_timeout()}
        end
    end
  end

  defp reloaded(%__MODULE__{status: "serving"} = probed, from, after_promote?, tunnel) do
    new_state = %{probed | serving_commit: current_commit(probed)}
    persist!(new_state)
    new_state = ensure_tunnel(new_state, after_promote?, tunnel)

    Logger.info(
      "[CmsHarness] reload of #{new_state.root} done, serving #{new_state.serving_commit}"
    )

    reply_then_hook(
      from,
      {:ok, Map.put(result(new_state), :action, "reloaded")},
      new_state,
      after_promote?
    )
  end

  defp reloaded(%__MODULE__{status: "down"} = probed, from, after_promote?, tunnel),
    do: restart_instead(probed, from, after_promote?, tunnel, "the reload left the app down")

  defp reloaded(probed, _from, _after_promote?, _tunnel) do
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
      instance_id: state.instance_id,
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
      "instance_id" => state.instance_id,
      "status" => state.status,
      "url" => url(state.port, state.status),
      "commit" => state.commit,
      "serving_commit" => state.serving_commit,
      "reason" => reason
    })
  end

  # Alive and running in this copy's root: a persisted pid may have been
  # recycled, and a stop must never signal a stranger.
  defp running?(%__MODULE__{os_pid: nil}), do: false

  defp running?(%__MODULE__{os_pid: pid, root: root} = state) do
    Runner.alive?(pid) and Runner.process_root(pid) == CodeMySpec.Paths.expand(root) and
      not owned_by_another?(state, pid)
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
  defp start_first_run(state, after_promote?, tunnel) do
    case launch_process(state, tunnel) do
      {:ok, launched_state} ->
        window = first_start_probe_attempts() * health_wait_interval_ms()
        deadline = System.monotonic_time(:millisecond) + window
        settled_state = wait_for_health(launched_state, deadline)

        new_state =
          settled_state
          |> watch_if_booting("first start")
          |> ensure_tunnel(after_promote?, tunnel)

        {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}

      {:error, reason} ->
        new_state = ensure_tunnel(state, after_promote?, tunnel)
        {:reply, {:error, reason}, new_state, idle_timeout()}
    end
  end

  # Not serving by the inline window and its process still alive: reported as
  # `starting` and watched in the background toward the ceiling. `os_pid` is
  # set, so a concurrent `ensure_running` will not re-launch it. A restart
  # that recompiles every dep is still booting here, not down.
  defp watch_if_booting(%__MODULE__{status: "serving"} = state, _label), do: state

  defp watch_if_booting(state, label) do
    if Runner.alive?(state.os_pid) do
      deadline = System.monotonic_time(:millisecond) + first_start_ceiling_ms()

      new_state = %{
        state
        | status: "starting",
          first_start_deadline: deadline,
          slow_start: label
      }

      persist!(new_state)
      schedule_first_start_check()
      new_state
    else
      state
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

  # Port and database policy are independent, including configured HTTP with
  # a cloned database or allocated ports with the configured database.
  defp ensure_port_and_database(state) do
    ports =
      if state.port_mode == "configured",
        do: Runner.main_ports(state.root),
        else: {state.port || Runner.free_port(), state.https_port || Runner.free_port()}

    database =
      if state.database_mode == "configured",
        do: Runner.main_database_name(state.root),
        else: state.database || database_name(state)

    case ports do
      {http, https} when is_integer(http) and is_binary(database) ->
        {:ok, {state.port || http, state.https_port || https, state.database || database}}

      _ ->
        {:error, {:cannot_resolve_main_address, state.root}}
    end
  end

  # Main's fixed port may be held by an untracked server. Killed only when its
  # cwd is this checkout's root; anything else is refused, never killed.
  # Non-main ports come fresh from `free_port/0`.
  defp ensure_port_free(%__MODULE__{port_mode: "configured"} = state, port) do
    case Runner.listener_pid(port) do
      nil ->
        :ok

      pid ->
        if Runner.process_root(pid) == CodeMySpec.Paths.expand(state.root) and
             not owned_by_another?(state, pid) do
          Runner.stop_process(pid)
        else
          {:error, {:port_held_by_untracked_process, port, pid}}
        end
    end
  end

  defp ensure_port_free(_state, port) do
    case Runner.listener_pid(port) do
      nil -> :ok
      pid -> {:error, {:port_held_by_untracked_process, port, pid}}
    end
  end

  defp owned_by_another?(state, pid) do
    Enum.any?(descriptors_for_root(state.root), fn descriptor ->
      descriptor["instance_id"] != state.instance_id and descriptor["os_pid"] == pid
    end)
  end

  # The UUID suffix keeps clones independent even when they share a checkout.
  defp database_name(state) do
    app = Runner.app_name(state.root) || "app"

    suffix =
      state.instance_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "#{app}_dev_wc_#{suffix}"
  end

  # Drops only names in this module's own `_dev_wc_` convention: no undo.
  defp drop_database(%__MODULE__{database_mode: "clone", database: database})
       when is_binary(database) do
    if safe_identifier?(database) and String.contains?(database, "_dev_wc_") do
      Runner.drop_database(database)
    else
      {:error, {:unsafe_database_name, database}}
    end
  end

  defp drop_database(_state), do: :ok

  defp ensure_database(%{database_mode: "configured"}, _database), do: :ok

  defp ensure_database(state, database) do
    if Runner.database_exists?(database), do: :ok, else: clone_database(state, database)
  end

  defp clone_database(state, database) do
    main_db = state.database_source || default_database_source(state)

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

  defp default_database_source(%{default: true, root: root}), do: Runner.main_database_name(root)
  defp default_database_source(_), do: nil

  @doc """
  Whether `name` is safe to interpolate into the shell string
  `CmsHarness.AppInstance.Runner.Local.clone_database/3` builds. Public so it
  is tested.
  """
  def safe_identifier?(name), do: is_binary(name) and Regex.match?(~r/^[a-zA-Z0-9_]+$/, name)

  defp current_commit(state), do: Runner.current_commit(state.root)

  # A copy's app serves the code it started on, while merging main into the
  # copy moves HEAD under it: migrations go unapplied and a changed mix.lock or
  # config fails the code reloader, and the app stays down until someone
  # restarts it. Main's app is brought current by its promote, not here.
  defp head_moved?(%__MODULE__{persistent: true}), do: false

  defp head_moved?(%__MODULE__{serving_commit: serving} = state) when is_binary(serving),
    do: running?(state) and current_commit(state) not in [nil, serving, state.brought_to]

  defp head_moved?(_state), do: false

  # The result as reported, with the reload under way when HEAD has moved.
  defp catching_up(state) do
    if head_moved?(state) do
      send(self(), :bring_current)

      Map.put(
        result(state),
        :action_reason,
        "HEAD moved past the serving commit #{state.serving_commit}; the app is being " <>
          "migrated and reloaded (or restarted) onto it now."
      )
    else
      result(state)
    end
  end

  # A clause that answers directly rather than through `reply_then_hook/4`.
  defp as_noreply({:reply, reply, state, timeout}) do
    send(self(), {:bring_current_reply, reply})
    {:noreply, state, timeout}
  end

  defp as_noreply(noreply), do: noreply

  defp reloader_cannot_take?(%__MODULE__{serving_commit: serving} = state)
       when is_binary(serving) do
    case current_commit(state) do
      nil ->
        false

      ^serving ->
        false

      head ->
        state.root
        |> Runner.changed_paths(serving, head)
        |> List.wrap()
        |> Enum.any?(&deps_or_config?/1)
    end
  end

  defp reloader_cannot_take?(_state), do: false

  defp deps_or_config?(path),
    do: path in ["mix.lock", "mix.exs"] or String.starts_with?(path, "config/")

  defp launch(state, port, https_port, database, tunnel) do
    Runner.launch(
      state.root,
      port,
      https_port,
      database,
      state.log_path,
      state.port_mode == "configured",
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

  # A start replies inside the call that asked for it. Reserve at least a
  # second for stop, launch, and the reply; a short configured call timeout
  # otherwise leaves only a few milliseconds after the health wait.
  defp settle_by(call_timeout) do
    health_wait = max(call_timeout - max(div(call_timeout, 4), 1_000), 0)
    System.monotonic_time(:millisecond) + health_wait
  end

  defp health_wait_interval_ms,
    do: Application.get_env(:code_my_spec, :app_instance_health_wait_interval_ms, 1_000)

  defp stop_if_running(%{os_pid: nil} = state), do: {:ok, persist_stopped(state)}

  defp stop_if_running(state),
    do: confirm_stop(state, Runner.alive?(state.os_pid), Runner.process_root(state.os_pid))

  defp confirm_stop(%{os_pid: pid}, true, nil),
    do: {:error, {:cannot_confirm_process_stopped, pid}}

  defp confirm_stop(%{root: root} = state, true, root) do
    if owned_by_another?(state, state.os_pid) do
      {:ok, persist_stopped(state)}
    else
      stop_process(state)
    end
  end

  defp confirm_stop(state, _alive?, _root), do: {:ok, persist_stopped(state)}

  defp stop_process(%__MODULE__{os_pid: pid} = state) when is_integer(pid) do
    with :ok <- Runner.stop_process(pid) do
      {:ok, persist_stopped(state)}
    end
  end

  defp persist_stopped(state) do
    new_state = %{state | status: "down", os_pid: nil, first_start_deadline: nil}
    persist!(new_state)
    new_state
  end

  # --- Internals: tunnel ---
  #
  # The harness holds the tunnel, not the app, so an app restart keeps the
  # connector. Whether to hold one is decided by whether one was handed over,
  # never by main-ness; copies handed the same tunnel share one connector.
  # Handed none: nothing to run and nothing stopped (a shared connector carries
  # other copies' addresses). See knowledge/harness, "App instances".
  defp ensure_tunnel(state, _after_promote?, nil), do: state

  # Already running this tunnel: re-checked each call, since an unlinked
  # connector can die on its own.
  defp ensure_tunnel(
         %__MODULE__{tunnel_pid: pid, tunnel_id: id} = state,
         _after_promote?,
         %{tunnel_id: id} = tunnel
       )
       when is_pid(pid) do
    if Process.alive?(pid),
      do: state,
      else: start_tunnel(%{state | tunnel_pid: nil, tunnel_id: nil}, tunnel)
  end

  # Holding a tunnel for different credentials: swap to the new ones.
  defp ensure_tunnel(%__MODULE__{tunnel_pid: pid} = state, _after_promote?, tunnel)
       when is_pid(pid) do
    Runner.stop_tunnel(pid)
    start_tunnel(%{state | tunnel_pid: nil, tunnel_id: nil}, tunnel)
  end

  defp ensure_tunnel(state, _after_promote?, tunnel), do: start_tunnel(state, tunnel)

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
      "instance_id" => state.instance_id,
      "working_copy_id" => state.working_copy_id,
      "root" => state.root,
      "default" => state.default,
      "persistent" => state.persistent,
      "port_mode" => state.port_mode,
      "database_mode" => state.database_mode,
      "database_source" => state.database_source,
      "after_promote" => state.after_promote,
      "log_path" => state.log_path,
      "port" => state.port,
      "https_port" => state.https_port,
      "database" => state.database,
      "os_pid" => state.os_pid,
      "commit" => state.commit,
      "serving_commit" => state.serving_commit,
      "status" => state.status
    }

    atomic_write!(state.state_path, Jason.encode!(payload))
    index_source(state)
    write_database_name_status(state)
  end

  # Story 1013: the harness-managed boot sets DATABASE_NAME for the OS
  # process it launches, but a plain `mix run`/`iex -S mix` run by hand in
  # the same checkout never sees that env var and silently queries the
  # shared main database instead -- a result that looks right and is wrong.
  # Written inside the checkout, where config/dev.exs can read it back.
  # Main is excluded: its database is always config/dev.exs's own literal
  # default, not a per-copy name, so there is nothing of its own to record.
  defp write_database_name_status(%__MODULE__{default: false}), do: :ok

  defp write_database_name_status(%__MODULE__{database_mode: "configured"}), do: :ok

  defp write_database_name_status(%__MODULE__{database: database}) when not is_binary(database),
    do: :ok

  defp write_database_name_status(state) do
    path = Path.join(state.root, ".code_my_spec/status/database_name")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, state.database)
  end

  defp clear_database_name_status(%{
         default: true,
         database_mode: "clone",
         database: database,
         root: root
       })
       when is_binary(database) do
    path = Path.join(root, ".code_my_spec/status/database_name")

    case File.read(path) do
      {:ok, ^database} -> File.rm(path)
      _ -> :ok
    end
  end

  defp clear_database_name_status(_), do: :ok

  defp restore_persisted(state) do
    case File.read(state.state_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"instance_id" => id, "root" => root} = decoded}
          when id == state.instance_id and root == state.root ->
            apply_persisted(state, decoded)

          _ ->
            state
        end

      {:error, _} ->
        state
    end
  end

  defp apply_persisted(state, decoded) do
    %{
      state
      | log_path: decoded["log_path"] || state.log_path,
        port: decoded["port"],
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
  @spec reported(map()) :: map() | nil
  def reported(descriptor) do
    case File.read(state_path(descriptor)) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = decoded} ->
            %{
              "instance_id" => decoded["instance_id"],
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

  defp state_path(%{"instance_id" => id}) do
    Path.join([instances_root(), id, "state.json"])
  end

  defp log_path(%{"instance_id" => id}) do
    Path.join([instances_root(), id, "app.log"])
  end

  defp instance_key(root) do
    :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp retire_legacy_claim(state) do
    path = Path.join([instances_root(), instance_key(state.root), "instance-owner"])

    case File.read(path) do
      {:ok, id} when id == state.instance_id -> File.write!(path, "discarded:" <> id)
      _ -> :ok
    end
  end

  defp import_legacy(%{default: false} = state), do: state

  defp import_legacy(state) do
    legacy_dir = Path.join(instances_root(), instance_key(state.root))
    legacy_state = Path.join(legacy_dir, "state.json")

    if not File.exists?(state.state_path) and File.exists?(legacy_state) do
      case File.open(Path.join(legacy_dir, "instance-owner"), [:write, :exclusive]) do
        {:ok, file} ->
          IO.binwrite(file, state.instance_id)
          File.close(file)
          adopt_legacy(state, legacy_state, legacy_dir)

        {:error, :eexist} ->
          if File.read(Path.join(legacy_dir, "instance-owner")) == {:ok, state.instance_id},
            do: adopt_legacy(state, legacy_state, legacy_dir),
            else: state

        _ ->
          state
      end
    else
      state
    end
  end

  defp adopt_legacy(state, path, dir) do
    with {:ok, contents} <- File.read(path), {:ok, decoded} <- Jason.decode(contents) do
      restored = apply_persisted(state, Map.put(decoded, "log_path", Path.join(dir, "app.log")))

      # A recycled PID is retained only as historical data; running?/1 checks ownership before signals.
      persist!(restored)
      restored
    else
      _ -> state
    end
  end

  defp atomic_write!(path, contents) do
    temporary = path <> ".tmp"
    File.write!(temporary, contents)
    File.rename!(temporary, path)
  end

  defp source_index_path(root),
    do: Path.join([instances_root(), "source-index", instance_key(root) <> ".json"])

  defp indexed_ids(root) do
    with {:ok, data} <- File.read(source_index_path(root)),
         {:ok, ids} when is_list(ids) <- Jason.decode(data),
         do: ids,
         else: (_ -> [])
  end

  defp index_source(state) do
    :global.trans({{__MODULE__, :source_index, state.root}, self()}, fn ->
      ids = indexed_ids(state.root)

      unless state.instance_id in ids do
        path = source_index_path(state.root)
        File.mkdir_p!(Path.dirname(path))
        atomic_write!(path, Jason.encode!([state.instance_id | ids]))
      end
    end)
  end

  def descriptors_for_root(root) do
    root = CodeMySpec.Paths.expand(root)

    for id <- indexed_ids(root),
        {:ok, _} <- [Ecto.UUID.cast(id)],
        path = Path.join([instances_root(), id, "state.json"]),
        {:ok, data} <- [File.read(path)],
        {:ok, descriptor} <- [Jason.decode(data)],
        descriptor["root"] == root,
        {:ok, descriptor} <- [validate_descriptor(descriptor)],
        do: descriptor
  end

  def reported_for_root(root) do
    Enum.map(descriptors_for_root(root), &reported/1)
  end

  def legacy_reported(root) do
    path = Path.join([instances_root(), instance_key(root), "state.json"])

    with false <- File.exists?(Path.join(Path.dirname(path), "instance-owner")),
         {:ok, data} <- File.read(path),
         {:ok, decoded} <- Jason.decode(data) do
      %{
        "status" => decoded["status"],
        "commit" => decoded["commit"],
        "serving_commit" => decoded["serving_commit"],
        "url" => url(decoded["port"], decoded["status"])
      }
    else
      _ -> nil
    end
  end

  @doc """
  The directories a checkout's own app instance keeps its state and log in:
  one named for the working copy, one for the checkout's path.
  """
  @spec own_dirs(String.t(), String.t() | nil) :: [String.t()]
  def own_dirs(root, working_copy_id) do
    [instance_key(root), working_copy_id]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.join(instances_root(), &1))
  end

  @doc "Where every app instance keeps its state and log, one directory each."
  def instances_root do
    Application.get_env(
      :code_my_spec,
      :app_instances_root,
      Path.join(CodeMySpec.Paths.user_state_dir(), "app-instances")
    )
  end
end
