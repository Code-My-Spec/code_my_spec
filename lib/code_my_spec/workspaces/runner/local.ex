defmodule CodeMySpec.Workspaces.Runner.Local do
  @moduledoc """
  Runs an instance as a real OS process on this machine — no Docker.

  Mirrors `docker/devbox/entrypoint.sh`'s own sequence, because that script is
  already the proven answer to "how does a CodeMySpec project come up from
  nothing": generate with `mix cms.new` (or reuse what is already there), fetch
  dependencies, set up the database, start the harness, start the app. This
  runs the same five steps directly on the host instead of inside a container.

  ## What Docker was doing for free, and is not free here

  A container gives each instance its own filesystem, its own loopback (so
  `cms start` can always bind :4003 and the app can always bind :4000), and one
  `docker rm --force` that tears down everything at once. None of that exists
  on bare metal:

    * Each instance gets its own directory under `workspace_root/0` instead of
      its own filesystem.
    * The app is told its port with `PORT`, because two instances cannot both
      bind :4000 on one host the way two containers can. The harness gets its
      own free port for the same reason — `cms start` defaulting to :4003
      would collide with a harness already serving this machine's own working
      copies.
    * Teardown is a process tree this module owns and kills, not a daemon call.

  ## Prerequisites are out of scope here

  This assumes Elixir, Erlang and Postgres are already on the machine — the
  same assumption the container's base image makes by being built with them
  already installed. Detecting and installing what is missing on an unknown
  host is a different kind of problem (diagnose-and-adapt, not a fixed
  sequence) and belongs to whatever bootstraps prerequisites, not to this
  module.

  ## Persisting past this BEAM

  The detached script is launched with `setsid` where available (Linux) so it
  survives this process the way a container survives the daemon's caller. On
  macOS, which ships no `setsid`, the child is merely disowned (`disown`
  inside the subshell) — it survives this function returning, but a full
  supervisor tree restart could still orphan it while leaving the row
  pointing at a live process `alive?/1` can no longer find. Known gap, not
  silently assumed away.
  """

  @behaviour CodeMySpec.Workspaces.Runner

  alias CodeMySpec.Environments

  require Logger

  @impl true
  def start(container_name, app_name, port, _env \\ []) do
    stop(container_name)

    dir = workspace_dir(container_name)
    File.mkdir_p!(dir)

    app_dir = Path.join(dir, app_name)
    log_file = log_path(dir)
    File.write!(log_file, "")

    harness_port = free_port()
    script = build_script(dir, app_dir, app_name, port, harness_port)
    script_path = Path.join(dir, "run.sh")
    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)

    case launch(script_path, log_file) do
      {:ok, pid} ->
        write_state(dir, %{pid: pid, port: port, harness_port: harness_port})
        :ok

      {:error, reason} ->
        {:error, "could not launch #{script_path}: #{inspect(reason)}"}
    end
  end

  # The whole boot as one script, not a series of `System.cmd/3` calls from
  # here. `start/3` has to return as soon as the runner accepts the instance
  # — `Workspaces.boot/1`'s caller is a LiveView mount waiting on it — and
  # generating, fetching deps and migrating together can run a minute or more.
  # A container backgrounds that same work by being `docker run --detach`;
  # this backgrounds it by launching one script and returning immediately.
  #
  # `log()`'s format matches `docker/devbox/entrypoint.sh`'s exactly —
  # `\n==> message\n` — because `BootSteps.announced?/2` is the reader on the
  # other end and it was written against that script's output. No changes
  # there; this produces what it already expects.
  #
  # The started app's marker still says "on :4000" regardless of the real
  # port. That string is `BootSteps`' literal, fixed marker — Docker's own
  # entrypoint is only accurate there because the *container's* internal port
  # never changes; only the externally published one does. This runner has no
  # such internal/external split, so the line is informational scaffolding
  # for the same marker match, not a claim about where the app is actually
  # bound — `PORT` is what actually places it.
  defp build_script(dir, app_dir, app_name, port, harness_port) do
    """
    #!/bin/bash
    set -uo pipefail

    log() { printf '\\n==> %s\\n' "$*"; }

    if [ ! -f "#{app_dir}/mix.exs" ]; then
      log "Generating #{app_name} with mix cms.new"
      mkdir -p "#{dir}"
      cd "#{dir}"
      mix cms.new "#{app_name}" --no-install || exit 1
    else
      log "Reusing existing project at #{app_dir}"
    fi

    cd "#{app_dir}"

    log "Fetching dependencies"
    mix deps.get || exit 1

    log "Setting up the database"
    mix ecto.create
    mix ecto.migrate || exit 1

    log "Starting the cms harness server on :#{harness_port}"
    CMS_HARNESS_PORT=#{harness_port} cms start &

    log "Starting #{app_name} on :4000"
    exec env PORT=#{port} mix phx.server
    """
  end

  defp launch(script_path, log_file) do
    setsid = System.find_executable("setsid")

    shell =
      if setsid do
        "#{setsid} #{script_path} > #{log_file} 2>&1 < /dev/null & echo $!"
      else
        "#{script_path} > #{log_file} 2>&1 < /dev/null & disown; echo $!"
      end

    # `merge_clean_env/1`, not `clean_otp_env/0` alone: the script runs `mix
    # cms.new` inside a brand-new project directory pinning its own Elixir
    # (`~> 1.20`), and `clean_otp_env/0` only scrubs the release's own PATH
    # entries — it does not put an asdf/mise shim ahead of this BEAM's
    # already-resolved Elixir the way `merge_clean_env/1` does. Without that,
    # the spawned `mix` inherited our resolved toolchain and `mix cms.new`
    # failed with "The task \"cms.new\" could not be found" whenever the
    # pinned version's `cms_new` archive wasn't installed under the parent's
    # own Elixir (114843ff).
    env = Environments.merge_clean_env(env: [])[:env]

    case System.cmd("bash", ["-c", shell],
           stderr_to_stdout: true,
           env: env
         ) do
      {out, 0} ->
        case out |> String.trim() |> Integer.parse() do
          {pid, _} -> {:ok, pid}
          :error -> {:error, "no pid on launch: #{inspect(out)}"}
        end

      {out, code} ->
        {:error, "launch exited #{code}: #{String.trim(out)}"}
    end
  end

  @impl true
  def healthy?(port) when is_integer(port), do: serving(port) != :down

  @impl true
  def serving(port) when is_integer(port) do
    case get(port) do
      {:ok, %Req.Response{status: status}} when status >= 500 -> :erroring
      {:ok, %Req.Response{}} -> :serving
      _ -> :down
    end
  end

  defp get(port) do
    Req.get(
      "http://127.0.0.1:#{port}/",
      [
        retry: false,
        receive_timeout: 2_000,
        connect_options: [timeout: 1_000]
      ] ++ req_plug()
    )
  end

  # Pinnable under test, like every other Req caller here.
  #
  # The usual argument for pinning is a credential leaking into a real request.
  # This one carries none — it is a loopback probe — and the risk is the other
  # way round: the port is an argument, so a test that passes 4000 probes the
  # developer's own dev server and reads whatever it says as this workspace's
  # health. `HttpClientsAreStubbableTest` is right to demand it even though the
  # usual reason does not apply.
  defp req_plug do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  @impl true
  def url(_container_name, port), do: "http://localhost:#{port}"

  @impl true
  def alive?(container_name) do
    case read_state(container_name) do
      %{"pid" => pid} when is_integer(pid) -> os_pid_alive?(pid)
      _ -> false
    end
  end

  # `kill -0` sends no signal, only checks whether the pid could be signalled
  # at all — the standard, portable "is this pid still there" probe.
  defp os_pid_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  @impl true
  def logs(container_name) do
    container_name
    |> workspace_dir()
    |> log_path()
    |> File.read()
    |> case do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  @impl true
  def stop(container_name) do
    case read_state(container_name) do
      %{"pid" => pid} when is_integer(pid) -> kill_tree(pid)
      _ -> :ok
    end

    :ok
  end

  # The process group, not just the recorded pid. `mix phx.server` is what
  # gets tracked, but it is a parent of a BEAM node which is itself a parent
  # of however many workers a Phoenix app runs — killing only the leader
  # leaves the tree running, attached to nothing this module can find again.
  # `pkill -P` walks children; the leader gets the same signal directly in
  # case it has none.
  defp kill_tree(pid) do
    System.cmd("pkill", ["-TERM", "-P", Integer.to_string(pid)], stderr_to_stdout: true)
    System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp write_state(dir, state) do
    File.write!(state_path(dir), Jason.encode!(state))
  end

  defp read_state(container_name) do
    container_name
    |> workspace_dir()
    |> state_path()
    |> File.read()
    |> case do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = decoded} -> decoded
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp state_path(dir), do: Path.join(dir, ".runner_state.json")
  defp log_path(dir), do: Path.join(dir, "run.log")

  defp workspace_dir(container_name), do: Path.join(workspace_root(), container_name)

  defp workspace_root do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Workspaces, [])
    |> Keyword.get(:local_workspace_root, Path.expand("~/.codemyspec/workspaces"))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
