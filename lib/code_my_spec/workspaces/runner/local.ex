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
  def start(container_name, app_name, port, env \\ []) do
    stop(container_name)

    %{dir: dir, script_path: script_path, log_file: log_file, harness_port: harness_port} =
      prepare(container_name, app_name, port, env)

    case launch(script_path, log_file) do
      {:ok, pid} ->
        write_state(dir, %{pid: pid, port: port, harness_port: harness_port})
        :ok

      {:error, reason} ->
        {:error, "could not launch #{script_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Everything a workspace needs on disk before anything is launched.

  Split out so it can be asserted on. Driving `start/4` in a test spawns a real
  `mix cms.new`; what can regress here is whether the identity is written at
  all and what the script does with it — and blinding showed that testing
  `write_identity/2` alone leaves the call site uncovered, which is the half
  that was missing in `ac7a510b`.
  """
  @spec prepare(String.t(), String.t(), integer(), term()) :: map()
  def prepare(container_name, app_name, port, env \\ []) do
    dir = workspace_dir(container_name)
    File.mkdir_p!(dir)
    write_identity(dir, env)

    app_dir = Path.join(dir, app_name)
    log_file = log_path(dir)
    File.write!(log_file, "")

    harness_port = free_port()
    script = build_script(dir, app_dir, app_name, port, harness_port)
    script_path = Path.join(dir, "run.sh")
    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)

    %{
      dir: dir,
      app_dir: app_dir,
      script_path: script_path,
      log_file: log_file,
      harness_port: harness_port
    }
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

    # The copy claims its identity from a file, never from the environment.
    #
    # `HarnessConfig.read/1` says why in its own words: "The file is the answer,
    # and the only one — no environment fallback, not even when there is no file
    # at all", because the env used to win and collapsed every root onto one id.
    # So the host writes `.cms_harness.json` beside the workspace before this
    # script runs, and the only thing left to do is put it where the generated
    # application's root is — `HarnessConfig.path/1` looks exactly there and
    # does not walk up.
    #
    # Without this the workspace comes up holding an application and nothing
    # else: no identity, the copy is never served, and the agent asked for on it
    # is never confirmed. That is what a paying customer got — "Not being
    # served", "1 agent asked for, none confirmed yet", and a message to the
    # agent refused with "a copy on a new project usually has no deploy key of
    # its own yet" (`ac7a510b`). `docker/devbox/entrypoint.sh` has done the
    # equivalent all along; this runner had no step for it.
    #
    # Absent, skipped rather than failed, for the same reason the container path
    # skips: a workspace started by hand has no host to have told it anything
    # and should still come up.
    if [ -f "#{dir}/.cms_harness.json" ]; then
      log "Claiming this workspace's identity"
      mv "#{dir}/.cms_harness.json" "#{app_dir}/.cms_harness.json"
    else
      log "No identity written for this workspace; starting un-onboarded"
    fi

    log "Starting the cms harness server on :#{harness_port}"
    CMS_HARNESS_PORT=#{harness_port} cms start &

    log "Starting #{app_name} on :4000"
    exec env PORT=#{port} mix phx.server
    """
  end

  @doc """
  How a boot script is shelled out.

  `merge_clean_env/1`, not `clean_otp_env/0`, and the difference is the whole
  bug. The scrub clears the release and `MIX_*` variables but leaves PATH in
  whatever order this server inherited — and under a version manager that order
  names our own resolved Elixir *ahead* of the shims, because that is how we got
  our Elixir. A child `mix` inherits that resolution wholesale.

  The script runs `mix cms.new` in a brand-new empty directory, which pins no
  version of its own, so the shims would have fallen back to the machine's
  default. Instead it got ours — 1.19.4-otp-28, where `cms_new` is not
  installed as an archive — and every boot died on

      ** (Mix) The task "cms.new" could not be found

  Deterministic, not flaky: four rounds of story 1033's QA, each attributed to
  disk exhaustion or Docker, on a box with 33GiB free running no containers at
  all (`114843ff`). The error was only ever in the workspace's own `run.log`,
  which nothing was reading.

  `Environments.merge_clean_env/1`'s own comment names this exact situation —
  "the two callers that run a child mix inside another project's directory,
  which is the only situation where whose toolchain resolves is a question".
  This was a third such caller and was not on the list.

  Public so the environment can be asserted on without shelling anything out.
  """
  @spec launch_env() :: keyword()
  def launch_env, do: Environments.merge_clean_env(stderr_to_stdout: true)

  # What the host knows about this copy, written where the copy will look.
  #
  # `Workspaces.instance_env/1` already mints the id and assembles the deploy
  # key and server url; they were handed to `start/4` and this runner dropped
  # them, which is `ac7a510b`. They are written to a file rather than exported,
  # because identity is read from `.cms_harness.json` and from nowhere else.
  #
  # Beside the workspace rather than inside the application, because the
  # application does not exist yet — `mix cms.new` creates it, and a generator
  # will not run into a directory somebody has already put files in. The script
  # moves it in once the tree is there.
  #
  # 0600, and never into the script text: it carries a deploy key, and a script
  # on disk is readable by anyone on the machine.
  @doc """
  Write what the host knows about this copy, where the copy will read it.

  Public because it is the part worth asserting on: driving `start/4` launches a
  real workspace, and what can regress here is which fields land and who can
  read them.
  """
  @spec write_identity(String.t(), term()) :: :ok
  def write_identity(dir, env) do
    # `instance_env/1` hands back string-keyed 2-tuples, not a keyword list, so
    # `env[:KEY]` finds nothing and finds it silently.
    fields = %{
      "working_copy_id" => value(env, "CMS_WORKING_COPY_ID"),
      "project_id" => value(env, "CMS_PROJECT_ID"),
      "deploy_key" => value(env, "CMS_DEPLOY_KEY"),
      "server_url" => value(env, "CMS_SERVER_URL")
    }

    fields
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
    |> put_identity(dir)
  end

  defp value(env, key) when is_list(env) do
    case List.keyfind(env, key, 0) do
      {^key, v} -> v
      _ -> nil
    end
  end

  defp value(_env, _key), do: nil

  # No id, nothing to claim. A workspace started by hand comes up un-onboarded
  # rather than failing, which is what the container path does too.
  defp put_identity(fields, _dir) when map_size(fields) == 0, do: :ok

  defp put_identity(fields, dir) do
    file = Path.join(dir, ".cms_harness.json")
    File.write!(file, Jason.encode_to_iodata!(fields))
    File.chmod!(file, 0o600)
    :ok
  end

  defp launch(script_path, log_file) do
    setsid = System.find_executable("setsid")

    shell =
      if setsid do
        "#{setsid} #{script_path} > #{log_file} 2>&1 < /dev/null & echo $!"
      else
        "#{script_path} > #{log_file} 2>&1 < /dev/null & disown; echo $!"
      end

    case System.cmd("bash", ["-c", shell], launch_env()) do
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
