defmodule CodeMySpec.Workspaces.Runner.Local do
  @moduledoc """
  Runs an instance as a real OS process on this machine — no Docker.

  Mirrors `docker/devbox/entrypoint.sh`: generate with `mix cms.new` (or
  reuse), fetch deps, set up the database, claim the identity, start the
  harness, start the app.

  What a container gave for free is done by hand: each instance gets its own
  directory under the workspace root; the app gets its port via `PORT` and the
  harness its own free port (two cannot share :4000/:4003 on one host);
  teardown kills a process tree this module owns.

  Assumes Elixir, Erlang and Postgres are installed.

  Launched with `setsid` where available (Linux). macOS has none, so the child
  is only disowned: a full supervisor restart could orphan it while the row
  points at a pid `alive?/1` can no longer find. Known gap.
  """

  @behaviour CodeMySpec.Workspaces.Runner

  alias CodeMySpec.Environments

  require Logger

  @impl true
  def id, do: :local

  @impl true
  def label, do: "Local"

  @impl true
  def kind, do: :local

  @impl true
  def instructions(%{token: token, server_url: server_url}) do
    [
      %{
        key: "setup-local",
        copy: "copy-setup-local",
        title: "Start the harness on this machine",
        body: """
        Install cms, then start the harness with this box's token:

        brew install code-my-spec/tap/cms
        CMS_SERVER_URL=#{server_url} CMS_DEVICE_TOKEN=#{token} cms harness
        """
      }
    ]
  end

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

  Split out so it can be asserted on without spawning a real `mix cms.new`:
  whether the identity is written, and what the script does with it.
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
    script = build_script(container_name, dir, app_dir, app_name, port, harness_port)
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

  # One detached script, so `start/4` returns at once (its caller is a
  # LiveView mount; the boot can take minutes).
  #
  # `log()` matches the devbox entrypoint's `\n==> message\n` format, which
  # `BootSteps.announced?/2` reads. "on :4000" is `BootSteps`' fixed marker,
  # not where the app binds — `PORT` places it.
  #
  # Both harness variables are load-bearing: `CMS_NODE_NAME` gives each
  # workspace a unique node name (the default `codemyspec` collides with the
  # box's own harness), and `CMS_PROJECT_DIR` makes the harness serve this
  # project at boot (no hook will ever arrive to pick it up).
  # `CmsHarness.Device.path/0` derives the workspace's device from it too.
  defp build_script(container_name, dir, app_dir, app_name, port, harness_port) do
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
    export CMS_NODE_NAME="#{container_name}"
    export CMS_HARNESS_PORT="#{harness_port}"
    export CMS_PROJECT_DIR="#{app_dir}"
    #{harness_source().command()} &

    log "Starting #{app_name} on :4000"
    exec env PORT=#{port} mix phx.server
    """
  end

  @doc """
  How a boot script is shelled out.

  `Environments.merge_clean_env/1`, not `clean_otp_env/0`: the script runs a
  child `mix` in another project's directory, and it must resolve the
  machine's toolchain (where `cms_new` is installed), not this server's
  Elixir ahead of the version-manager shims on PATH.

  Public so the environment can be asserted on without shelling anything out.
  """
  @spec launch_env() :: keyword()
  def launch_env, do: Environments.merge_clean_env(stderr_to_stdout: true)

  # A file, not env vars: identity is read from `.cms_harness.json` only.
  # Written beside the workspace, since `mix cms.new` will not generate into a
  # non-empty directory; the script moves it in. 0600 and never in the script
  # text: it carries a deploy key.
  @doc """
  Write what the host knows about this copy (`Workspaces` passes it to
  `start/4`) as `.cms_harness.json` in `dir`, mode 0600. Nothing is written
  when there is nothing to write.

  Public so which fields land, and who can read them, can be asserted on.
  """
  @spec write_identity(String.t(), term()) :: :ok
  def write_identity(dir, env) do
    # `env` is string-keyed 2-tuples, not a keyword list (`env[:KEY]` finds
    # nothing, silently). The `preview_*` keys are what
    # `ClientUtils.Harness.Preview.config/2` reads to enable the tunnel.
    fields = %{
      "working_copy_id" => value(env, "CMS_WORKING_COPY_ID"),
      "project_id" => value(env, "CMS_PROJECT_ID"),
      "deploy_key" => value(env, "CMS_DEPLOY_KEY"),
      "server_url" => value(env, "CMS_SERVER_URL"),
      "preview_url" => value(env, "CMS_PREVIEW_URL"),
      "preview_tunnel_id" => value(env, "CMS_PREVIEW_TUNNEL_ID"),
      "preview_tunnel_secret" => value(env, "CMS_PREVIEW_TUNNEL_SECRET"),
      "preview_account_tag" => value(env, "CMS_PREVIEW_ACCOUNT_TAG"),
      "preview_embedder" => value(env, "CMS_PREVIEW_EMBEDDER")
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

  # Nothing to claim: a workspace started by hand comes up un-onboarded.
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

  # Pinnable under test: a test passing port 4000 would otherwise probe the
  # developer's own dev server.
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

  # `kill -0` sends no signal; it checks the pid still exists.
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

  # Children (`pkill -P`) and the recorded pid: killing only the leader leaves
  # its tree running, attached to nothing this module can find again.
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

  @doc """
  Where an instance of `app_name` under `container_name` actually lands.

  Under the configured `local_workspace_root` (`~/.codemyspec/workspaces` by
  default). `Workspaces.instance_root/1` asks this rather than assuming the
  container path, which the joining harness could never match.
  """
  @spec root(String.t(), String.t()) :: String.t()
  def root(container_name, app_name), do: container_name |> workspace_dir() |> Path.join(app_name)

  defp workspace_dir(container_name), do: Path.join(workspace_root(), container_name)

  defp workspace_root do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Workspaces, [])
    |> Keyword.get(:local_workspace_root, Path.expand("~/.codemyspec/workspaces"))
  end

  # Defaults to the published release, the right answer on a customer's
  # laptop; see `HarnessSource`.
  defp harness_source do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Workspaces, [])
    |> Keyword.get(:harness_source, CodeMySpec.Workspaces.HarnessSource.Installed)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
