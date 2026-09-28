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
  sibling of `ProjectSupervisor`/`AgentSupervisor` in `CmsHarness.Supervisor`,
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

  # Configurable, same reasoning as `Intake.Conversation.shape_timeout/0`: a
  # test proving the idle-stop path fires should not have to wait 30 real
  # minutes to do it.
  defp idle_timeout, do: Application.get_env(:code_my_spec, :app_instance_idle_timeout_ms, to_timeout(minute: 30))

  defp idle_check_interval,
    do: Application.get_env(:code_my_spec, :app_instance_idle_check_interval_ms, to_timeout(minute: 2))

  defstruct [
    :root,
    :port,
    :https_port,
    :database,
    :os_pid,
    :commit,
    :status,
    :log_path,
    :state_path,
    main?: false
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
  """
  @spec ensure_running(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_running(root, opts \\ []) do
    with {:ok, pid} <- find_or_start(root) do
      GenServer.call(pid, {:ensure_running, main?(opts)}, op_timeout())
    end
  end

  @doc "Stop this copy's app, then start it again on the current commit."
  @spec restart(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restart(root, opts \\ []) do
    with {:ok, pid} <- find_or_start(root) do
      GenServer.call(pid, {:restart, main?(opts)}, op_timeout())
    end
  end

  defp main?(opts), do: Keyword.get(opts, :main?, false)

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
        case DynamicSupervisor.start_child(CmsHarness.AppInstanceSupervisor, {__MODULE__, root}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp op_timeout, do: Application.get_env(:code_my_spec, :app_instance_op_timeout_ms, 120_000)

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
  def handle_call({:ensure_running, main?}, _from, state) do
    state = %{state | main?: main?}

    if running?(state) do
      new_state = probe(state)
      {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}
    else
      case start_app(state) do
        {:ok, new_state} -> {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}
        {:error, reason} -> {:reply, {:error, reason}, state, idle_timeout()}
      end
    end
  end

  @impl true
  def handle_call({:restart, main?}, _from, state) do
    state = %{state | main?: main?}
    stopped = if running?(state), do: stop_process(state), else: state

    case start_app(stopped) do
      {:ok, new_state} -> {:reply, {:ok, result(new_state)}, new_state, idle_timeout()}
      {:error, reason} -> {:reply, {:error, reason}, stopped, idle_timeout()}
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

  # --- Internals: status ---

  @doc """
  Public only so the shape can be tested without booting a real process —
  same reasoning as `AnalysisServer.insert_by_cost/2`.
  """
  def result(%__MODULE__{status: status, port: port, commit: commit}) do
    %{status: status || "down", url: url(port, status), commit: commit}
  end

  @doc "A stopped copy never reports the address it used to answer on."
  def url(_port, status) when status in [nil, "down"], do: nil
  def url(port, _status), do: "http://127.0.0.1:#{port}"

  defp running?(%__MODULE__{os_pid: nil}), do: false
  defp running?(%__MODULE__{os_pid: pid}), do: Runner.alive?(pid)

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

  defp start_app(state) do
    with :ok <- ensure_serve_recipe(state),
         {port, https_port, database} <- ensure_port_and_database(state),
         :ok <- ensure_database(state, database),
         {:ok, os_pid} <- launch(state, port, https_port, database) do
      new_state = %{
        state
        | port: port,
          https_port: https_port,
          database: database,
          os_pid: os_pid,
          commit: current_commit(state),
          status: "serving"
      }

      persist!(new_state)
      {:ok, wait_for_health(new_state)}
    end
  end

  defp ensure_serve_recipe(state) do
    if Runner.recipe?(state.root, "serve"), do: :ok, else: {:error, :no_start_recipe}
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
  defp ensure_port_and_database(%__MODULE__{port: port, https_port: https_port, database: database})
       when is_integer(port) and is_integer(https_port) and is_binary(database) do
    {port, https_port, database}
  end

  defp ensure_port_and_database(state) do
    {state.port || Runner.free_port(), state.https_port || Runner.free_port(),
     state.database || database_name(state)}
  end

  # `<app>_dev_wc_<hash of this copy's root>` — stable across restarts of this
  # same checkout, distinct from every other copy of the same project without
  # needing to ask anything for an id.
  defp database_name(state) do
    app = Runner.app_name(state.root) || "app"
    suffix = state.root |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower) |> binary_part(0, 8)
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

  defp launch(state, port, https_port, database) do
    Runner.launch(state.root, port, https_port, database, state.log_path)
  end

  # A short, bounded wait so the common case can report "serving" rather than
  # "started, ask again" — not a long one, since the caller (a QA session
  # starting) is already holding a call for this. Attempts and interval are
  # both configurable, same reasoning as the idle timeout: a spex proving "an
  # app that fails to boot is reported, not waited on" should not spend 15
  # real seconds finding that out against a scripted `Runner` that already
  # knows the answer on attempt one.
  defp wait_for_health(state, attempts \\ nil)

  defp wait_for_health(state, nil), do: wait_for_health(state, health_wait_attempts())

  defp wait_for_health(state, 0), do: probe(state)

  defp wait_for_health(state, attempts) do
    case probe(state) do
      %{status: "serving"} = new_state ->
        new_state

      _ ->
        Process.sleep(health_wait_interval_ms())
        wait_for_health(state, attempts - 1)
    end
  end

  defp health_wait_attempts, do: Application.get_env(:code_my_spec, :app_instance_health_wait_attempts, 15)

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

  # --- Internals: persistence ---

  defp persist!(state) do
    File.mkdir_p!(Path.dirname(state.state_path))

    payload = %{
      "port" => state.port,
      "https_port" => state.https_port,
      "database" => state.database,
      "os_pid" => state.os_pid,
      "commit" => state.commit,
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
    Application.get_env(:code_my_spec, :app_instances_root, Path.expand("~/.codemyspec/app-instances"))
  end
end
