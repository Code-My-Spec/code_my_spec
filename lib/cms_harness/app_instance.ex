defmodule CmsHarness.AppInstance do
  @moduledoc """
  One working copy's own instance of the app it holds — story 1108.

  Each copy runs on its own port and its own database, so QA can test a
  story's branch before it is promoted instead of finding out the hard way
  that a copy's own address silently served main's pre-fix code (issue
  2d612ae8, metric_flow: story 1103's fix was committed on the feature copy,
  but the only running app was main's).

  ## Where this borrows from

  The launch/track/kill strategy — a bash one-liner that backgrounds the
  process and echoes its pid, `setsid` where it exists and `disown` on macOS
  where it does not, state persisted to a JSON file rather than held only in
  this process's memory, `kill -0` for liveness, `pkill -TERM -P` then
  `kill -TERM` to take the whole process tree with it — is
  `CodeMySpec.Workspaces.Runner.Local`'s, written for the customer-facing
  Workspaces demo feature. That module runs on the CodeMySpec server, for an
  instance with no working copy at all; this one runs on the harness's own
  machine, for a working copy that already exists, and clones its starting
  data from main's dev database instead of booting empty.

  ## Why a process per copy, outside the project's own supervision chain

  `CmsHarness.Project.Supervisor` is `rest_for_one`: its channel client, its
  analyzer queue and its watcher all restart together because they answer to
  one join. This app has nothing to do with any one join — it must survive a
  reconnect, a channel blip, a `mix test` run in the same copy — so it is a
  sibling of its copy's channel chain and agents under `CmsHarness.Copy.Supervisor`,
  found by `root` in the same `CmsHarness.Registry` everything else here uses.

  ## Idle timeout

  Same shape as `CodeMySpec.Intake.Conversation`: every reply re-arms the
  idle timeout via the fourth element of the `{:reply, ..., state, timeout}`
  tuple, and `handle_info(:timeout, ...)` stops the process — `restart:
  :temporary`, because an idle stop is a normal exit, not a crash to recover
  from. Requests count as activity via the app's own log file: whether its
  mtime moved inside the window, checked on a periodic self-tick rather than
  by proxying traffic. A byte-level TCP relay would count requests exactly and
  survive a LiveView websocket for free, but it is a new piece of network
  infrastructure to get right; a log file every `mix phx.server` already
  writes needs none of that, at the cost of also counting non-request
  activity (a migration, a boot) as "not idle" — which only ever delays a stop
  a working copy nobody is using, never causes a wrong one.
  """

  use GenServer, restart: :temporary

  require Logger

  alias CmsHarness.AppInstance.Runner
  alias CmsHarness.Copy.Supervisor, as: Copy
  alias CmsHarness.Project.ChannelClient

  # Configurable, same reasoning as `Intake.Conversation.shape_timeout/0`: a
  # test proving the idle-stop path fires should not have to wait 30 real
  # minutes to do it.
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
    :root,
    :port,
    :https_port,
    :database,
    :os_pid,
    # The commit the process launched from.
    :commit,
    # The commit the app serves now: `commit` after a launch, the reload's
    # commit after a reload. Its own field so a reloaded app is not read as
    # still on its launch commit, and a launch commit is not rewritten.
    :serving_commit,
    :status,
    :log_path,
    :state_path,
    :tunnel_pid,
    :tunnel_id,
    # Monotonic `System.monotonic_time(:millisecond)` deadline for a first
    # start's 10-minute ceiling — `nil` outside that window. Deliberately
    # never persisted: it only drives the in-BEAM `Process.send_after/3`
    # polling loop below, and a harness restart mid-first-start loses that
    # loop's timer along with everything else in this BEAM anyway. The next
    # explicit `ensure_running` call after such a restart still finds the
    # detached `just serve` process alive (`os_pid`/`port` *are* persisted)
    # and probes it fresh — losing the exact "exceeded 10 min" wording on a
    # restart this rare is an accepted trade against persisting a deadline
    # nothing else needs to survive one.
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

  `main?: true` marks this as the project's designated copy, so main's app
  is never stopped for idling — told fresh on every call rather than
  remembered, since only the server knows who holds the designation and it
  can change while this process is alive.

  `tunnel:` carries main's own tunnel credentials when it holds one — same
  "told fresh, never remembered" reasoning as `main?`, and for the same
  underlying hazard: a copy that kept running a connector after losing the
  designation (or a copy that never held one running one anyway) is exactly
  the stray-connector bug this project has already shipped one fix for. See
  `ensure_tunnel/3`.

  `head` rides beside `commit`. The app restarts only on a promote, so once
  the copy's HEAD moves it is still serving `commit`; saying both keeps that
  from reading as a stale report (048d1f4f).
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

  2026-09-29 follow-up: a join is not an `ensure_app_running`/`restart_app`
  call, and used to carry no tunnel — so a harness restart (which this
  project's own after-promote recipe causes 13-30s after every promote, see
  `ensure_tunnel/3`'s own moduledoc) took a main copy's connector down with
  nothing to bring it back except a further `ensure_app_running`, which
  nothing calls on its own. That left a promoted copy's public preview down
  until an operator or agent happened to ask for its app again. The join
  reply now carries the same "told fresh" `tunnel` an app-ensure does, and
  this is where the harness acts on it.

  Resolved from `Runner.main_ports/1` rather than a running `AppInstance`'s
  own state, because there may be no running `AppInstance` for this root yet
  at join — a main copy's port is fixed by its own `config/dev.exs` rather
  than assigned like a QA copy's, so nothing here needs the app already
  launched, tracked, or even known about by this module.

  Idempotent by way of `Runner.start_tunnel/2`'s own `DynamicSupervisor`
  child id: calling this against a tunnel already running under
  `CmsHarness.TunnelSupervisor` finds it rather than duplicating it, the
  same guarantee `ensure_tunnel/3`'s own tunnel path relies on.
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
    # Through `find_or_start/1`, not a bare registry lookup: a harness
    # restart between a start and this stop takes the in-memory registration
    # with it, but `init/1` reads the persisted state file back — the same
    # reason `Runner.Local` persists to disk rather than to a process. A bare
    # lookup finding nothing here would report success while an orphaned
    # `mix phx.server` kept running and kept spending.
    with {:ok, pid} <- find_or_start(root) do
      GenServer.call(pid, :stop, op_timeout())
    end
  end

  @doc """
  Stop this copy's app and drop the database it was cloned into — offboarding,
  not idling. The clone and the process are both this feature's own disposable
  artifacts, never the user's checkout or main's database, so this is safe to
  do without asking; `WorkingCopies.offboard/2`'s own "never touches disk"
  rule is about the checkout, not about what this story's own clone left
  behind on the Postgres server beside it.
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

  # A reload compiles in place, and a promote's version bump to `mix.exs`
  # recompiles the whole project, so it gets the server's own restart ceiling.
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

  # A first start's background watch, past its own short inline reply
  # window (see `start_first_run/3`). Guarded on `first_start_deadline` so a
  # stray message reaching a copy that has since actually started (a
  # concurrent `ensure_running` call already saw it serving and cleared the
  # deadline) or been stopped is simply ignored rather than re-armed forever.
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
        # Neither settled nor out of time — still `starting`, regardless of
        # what this probe's raw HTTP answer was; a `down`/`erroring` reading
        # mid-compile is not a real failure yet.
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
    {:noreply, state, :infinity}
  end

  def handle_info(:timeout, state) do
    if running?(state) and recently_active?(state) do
      Process.send_after(self(), :timeout, idle_check_interval())
      {:noreply, state, :infinity}
    else
      new_state = if running?(state), do: stop_process(state), else: state
      {:stop, :normal, new_state}
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

  # The app stays up: migrations and the code reloader's compile run against
  # the live process, and the probe decides whether it took. A failure
  # replies an error and runs no hook — the caller restarts, and that
  # restart runs the hook, so the harness restarts once either way.
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

  # Main replies before the hook runs, not after: this repo's own
  # after-promote recipe (`just refresh-harness`) kills the very harness BEAM
  # that is answering this call, partway through running it. Nothing queued
  # behind that kill ever leaves this process, so the confirmation has to
  # already be handed off — reply first, then run the hook and only log what
  # it does. A reload and a restart reach the hook the same way.
  defp reply_then_hook(from, reply, new_state, true) do
    GenServer.reply(from, reply)
    after_promote(new_state)
    {:noreply, new_state, idle_timeout()}
  end

  defp reply_then_hook(_from, reply, new_state, false),
    do: {:reply, reply, new_state, idle_timeout()}

  # --- Internals: status ---

  @doc """
  Public only so the shape can be tested without booting a real process —
  same reasoning as `AnalysisServer.insert_by_cost/2`.
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

  # Pushed unprompted — the one case nothing is calling back to ask: a first
  # start whose result (`starting` → `serving`, or `starting` → `erroring`)
  # is discovered by this copy's own background watch, well after the
  # `ensure_app_running` call that started it already got its own `starting`
  # reply and returned. `WorkingCopies.record_app_status/2`'s own shape —
  # `record_app_result/2` on the server side reads the exact same three keys
  # from an `_result` reply, so this is not a new contract, just a new way
  # to reach it. `reason` rides along for whoever is watching this push
  # directly (a spex, an operator) — `record_app_status/2` never reads it,
  # so carrying it is not a schema change.
  defp deliver_app_status(state, reason \\ nil) do
    ChannelClient.deliver_app_status(state.root, %{
      "status" => state.status,
      "url" => url(state.port, state.status),
      "commit" => state.commit,
      "reason" => reason
    })
  end

  # A recycled pid is the hazard, not a hypothetical one. `os_pid` can come
  # from disk (`restore_persisted/1`, on every fresh `init/1`) as easily as
  # from a launch this same process watched happen, and between a stop and
  # the next check the OS is free to hand that number to anything. `alive?/1`
  # alone cannot tell "still ours" from "reassigned" — only that *something*
  # answers to it — so a stale `state.json` naming a dead process's old pid
  # reads as running the moment the OS reissues it, and a subsequent stop
  # would `kill -TERM` a stranger. Same check `ensure_port_free/2` already
  # makes before adopting a port: alive is necessary, the cwd matching this
  # copy's own root is what makes it *this* process rather than merely *a*
  # process.
  defp running?(%__MODULE__{os_pid: nil}), do: false

  defp running?(%__MODULE__{os_pid: pid, root: root}) do
    Runner.alive?(pid) and Runner.process_root(pid) == Path.expand(root)
  end

  # Requests count as activity by way of the log file `just serve` redirects
  # into — its mtime moving inside the idle window is read as "not idle."
  # This also counts a migration or a boot, which only ever delays a stop
  # nobody needed yet, never causes a wrong one.
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

  # The half `start_app/2` and `start_first_run/3` share: get the OS process
  # running and the state persisted, before either decides how long to wait
  # on it. `status: "starting"` here is only ever the value `wait_for_health/1,2`
  # sees on its own first (always-taken) probe — real `probe/1` output
  # overwrites it before either caller's own reply is built.
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

  # A copy that has never once come up — `commit` is set only once `launch_process/1`
  # succeeds, so its absence means exactly "no successful start yet," never
  # "started a while ago and idled out" (that copy's last-persisted commit
  # survives a stop). Only this case gets the long, backgrounded first-start
  # treatment below; an ordinary restart (`:restart`, or `ensure_running` on a
  # copy that has run before) keeps today's synchronous `start_app/1` path and
  # its existing, unchanged timeout.
  defp first_start?(%__MODULE__{commit: nil}), do: true
  defp first_start?(_state), do: false

  # Harness session, live QA defect: a cold `npm install` plus compile can
  # legitimately outrun the 120s ceiling every other `ensure_running` call
  # gets, and a `GenServer.call` that does not reply within its own timeout
  # reads as a crash to its caller — an agent's own tool-call timeout, not
  # just this one. So a first start never blocks past a short inline window
  # (`first_start_probe_attempts/0`, ~30s): if the app is not yet serving by
  # then, this replies `starting` right away — with the address, so the
  # caller knows where it will be — and keeps polling in the background
  # toward its own 10-minute ceiling (`first_start_ceiling_ms/0`), pushing
  # `app_status` unprompted the moment it actually resolves (see
  # `handle_info(:first_start_check, ...)`), rather than making the next
  # `ensure_app_running` call respond stale or wait through the launch again.
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
          # Not yet serving after the short window — reported as `starting`,
          # not whatever the raw probe answered (`down`/`erroring` mid-compile
          # is not a real failure yet), and never re-launched by a concurrent
          # `ensure_running` call in the meantime: `os_pid` is already set, so
          # `running?/1` is already true.
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

  # Story 1108, criterion 4663: the project-specific half of a promote's
  # restart. `Promotion.Runner.restart/3` only ever calls the generic half
  # (bring the app back up, the same as any other copy) — this repo's own
  # need to also refresh its harness afterward, because server and harness
  # here are the same codebase, cannot live in that shared module without
  # every other project's promotion also having to answer for it. So it is
  # an optional recipe instead: declared once, in this project's own
  # justfile, run from here — the same `Runner.recipe?/2` check `serve`
  # already uses — right after the app it names is confirmed serving.
  #
  # Only called for `main?`, and only from a successful `:restart` or `:reload`
  # (a promote deploys by one or the other) — never `:ensure_running`'s
  # "already running, just probe" or "never started before" branches, and
  # never for a non-main copy's own "HEAD moved" restart. The recipe lives in
  # this project's *shared* justfile, so every working copy's checkout has it
  # — calling it unconditionally would bounce the one shared harness every
  # time any agent's ordinary commit restarted their own copy's app, taking
  # every other agent's in-flight hooks down with it for no reason. A promote
  # is main's alone, so the hook is too.
  #
  # Its own failure can only be logged, never replied: by the time it runs,
  # `handle_call` has already handed the success reply to `from` (see above)
  # — the one case this hook exists for is a recipe that kills this very
  # process before anything queued after that reply could go out.
  #
  # A project with nothing declared pays nothing for a hook it never asked
  # for — `recipe?/2` is the same one-line `just --list` check either way.
  #
  # Logged on both sides because this repo's recipe restarts the harness
  # 13-30s later with nothing else saying so, and an old harness pid read
  # in that window looked like a restart that never happened (bf5fe2a4).
  # The recipe runs synchronously under this BEAM and kills it, so the
  # "done" line never lands here — the start line says what confirms it
  # instead, and is flushed to disk before the recipe can kill anything.
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

  # Reused across restarts once allocated — a stable address is worth more
  # than a fresh one, and QA bookmarking a link should not have it move under
  # them on every restart.
  #
  # `https_port` is allocated whether or not the app has an HTTPS endpoint —
  # cheaper than asking, and an app with none just never reads the variable.
  # Skipping it is what cost code_my_spec's own copy its first real start:
  # `HTTPS_PORT` unset fell back to config's default 4001, and boot failed
  # `:eaddrinuse` against main's own dev server already holding it.
  defp ensure_port_and_database(%__MODULE__{
         port: port,
         https_port: https_port,
         database: database
       })
       when is_integer(port) and is_integer(https_port) and is_binary(database) do
    {:ok, {port, https_port, database}}
  end

  # Main is not allocated a free port and a clone the way every other copy
  # is — it is the one address every bookmark, browser tab and the MCP
  # endpoint already point at, and its database is the real dev database,
  # not a disposable copy of it. Both come from main's own `config/dev.exs`,
  # the same source `Runner.main_database_name/1` already reads for cloning.
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

  # Main's port is fixed — read off `config/dev.exs`, not freshly allocated
  # the way every other copy's is — so it can already be held by a process
  # this instance never launched and holds no tracked `os_pid` for: this
  # checkout's own pre-story-1108 dev server, still running from before the
  # first unified restart or ensure ever ran against it. `running?/1` only
  # ever tracks a *persisted* `os_pid` (see `stop_process/1`), so that old
  # server would otherwise sit on the port forever — `launch/5`'s
  # `mix phx.server` either fails `:eaddrinuse` next to it, or somehow
  # answers alongside it.
  #
  # Adopted (killed) only once its own working directory is confirmed to be
  # this checkout's own root — never assumed from the port number alone,
  # since something entirely unrelated could be squatting on 4000. Anything
  # that fails that check is refused loudly instead of killed: `launch/5`
  # was never going to succeed next to it either way, and guessing wrong
  # here means killing a stranger's process.
  #
  # Never reached for a non-main copy: its port came from `free_port/0`
  # a moment ago, allocated by binding it and immediately closing it again,
  # so nothing else has had the chance to take it in between.
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

  # `<app>_dev_wc_<hash of this copy's root>` — stable across restarts of this
  # same checkout, distinct from every other copy of the same project without
  # needing to ask anything for an id.
  defp database_name(state) do
    app = Runner.app_name(state.root) || "app"

    suffix =
      state.root
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "#{app}_dev_wc_#{suffix}"
  end

  # Refuses anything that doesn't look like this module's own naming
  # convention — belt and suspenders on top of `discard/1` only ever being
  # called with this process's own state: a `DROP DATABASE` is exactly the
  # one command here with no undo.
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
  `CmsHarness.AppInstance.Runner.Local.clone_database/3` builds — public so a
  regression here is caught by a test, not discovered as a
  command-injection seam.
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

  # The tunnel map's hostname, atomised the same way `ensure_tunnel/3`'s own
  # clauses already pattern-match it — the one piece of it a booting app
  # needs to answer `Endpoint.url()` correctly from the moment it starts,
  # rather than only once something pointed the Cloudflare tunnel at it.
  defp tunnel_host(%{hostname: hostname}), do: hostname
  defp tunnel_host(_), do: nil

  # Until the app serves, its process exits, or `deadline` passes, whichever
  # comes first; the reply is the last probe. A fixed 15×1s used to end it, and
  # a boot that compiles takes longer: restart_app answered "down" for an app
  # that served 30s later, and the agent restarted it again (181d5fdd).
  # `erroring` does not end the wait — mid-boot, before the JS bundle is
  # built, a healthy app answers it.
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

    # A stale address on a stopped copy is the exact failure story 1108
    # exists to prevent — never left standing.
    new_state = %{state | status: "down"}
    persist!(new_state)
    new_state
  end

  defp stop_process(state), do: %{state | status: "down"}

  # --- Internals: tunnel ---
  #
  # 2026-09-29, John: "the harness should hold the tunnel, not the generated
  # app." An app restart (a promote, a crash, `just serve` bouncing) no
  # longer needs to take the connector down with it — this process's own
  # lifetime, not the OS child it launches and relaunches, is what the
  # tunnel's lifetime now follows. Only ever reached for `main?: true`; see
  # `ensure_running/2`'s doc and `CmsHarness.HarnessProjectChannel.put_tunnel/2`
  # for why a sharing sibling (criterion 1586) must never run a connector of
  # its own.
  #
  # The other side of that trade: the tunnel now lives and dies with *this*
  # process, not with the app. This repo's own `after-promote` recipe
  # restarts the harness BEAM 13-30s after every promote (see `after_promote/1`
  # above), which takes this tunnel down with it — where the old, app-held
  # tunnel survived a harness restart untouched. The public preview blips on
  # every promote now, where it did not before. Probably acceptable, since a
  # promote already restarts the app the preview is serving — but it is the
  # trade being made, not a side effect nobody chose.
  #
  # No feature flag: which side holds the tunnel is derived per copy from
  # data already here, not a switch somebody has to remember to flip. `tunnel`
  # is `nil` exactly when `PreviewTunnel.stored_credentials/1` found nothing
  # for this copy (this repo's own main today — its dev tunnel is still
  # `config/dev.exs`'s hardcoded bootstrap, no DB row) — and only then does
  # this do nothing, leaving the app free to keep running its own, exactly as
  # before. The moment a copy's tunnel *is* DB-backed, `tunnel` is never nil,
  # and the app is told not to start one of its own — see `launch/6`'s
  # `tunnel_held_by_harness?` and `Runner.launch/7`'s doc for the other half
  # of this: the two sides derive the same answer from the same fact, so
  # there is no window where both, or neither, are running one.
  defp ensure_tunnel(%__MODULE__{tunnel_pid: pid} = state, false, _tunnel) when is_pid(pid) do
    Runner.stop_tunnel(pid)
    %{state | tunnel_pid: nil, tunnel_id: nil}
  end

  defp ensure_tunnel(state, false, _tunnel), do: state

  # Main, but holds no tunnel of its own — nothing to run.
  defp ensure_tunnel(state, true, nil), do: state

  # Already running this exact tunnel — re-checked on every call rather than
  # trusted once: a connector this process did not itself stop can still
  # have died on its own, and `start_tunnel/2` starts it unlinked for
  # exactly this reason (see its own doc) — a dead tunnel should read as
  # "not running," not crash the process supervising it.
  defp ensure_tunnel(
         %__MODULE__{tunnel_pid: pid, tunnel_id: id} = state,
         true,
         %{tunnel_id: id} = tunnel
       )
       when is_pid(pid) do
    if Process.alive?(pid),
      do: state,
      else: start_tunnel(%{state | tunnel_pid: nil, tunnel_id: nil}, tunnel)
  end

  # Holding a tunnel already, but for different credentials — re-provisioned
  # under us. Swap to the new ones rather than leaving a connector answering
  # for a tunnel this copy no longer holds the secret for.
  defp ensure_tunnel(%__MODULE__{tunnel_pid: pid} = state, true, tunnel) when is_pid(pid) do
    Runner.stop_tunnel(pid)
    start_tunnel(%{state | tunnel_pid: nil, tunnel_id: nil}, tunnel)
  end

  defp ensure_tunnel(state, true, tunnel), do: start_tunnel(state, tunnel)

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

  # A running copy already has its own port persisted. An `ensure_running`/
  # `restart` whose `start_app` itself failed still reaches here — main's
  # port is fixed and known from its own `config/dev.exs` regardless of
  # whether its app ever came up, the same source `ensure_port_and_database/1`
  # already reads it from.
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
