defmodule CmsHarness.AppInstance.Runner.Local do
  @moduledoc """
  The real thing: `just`, `psql`, `pg_dump`, a real detached OS process.

  Moved out of `CmsHarness.AppInstance` itself so its orchestration logic —
  does this copy need cloning, is it idle, what a stopped copy reports — can
  be tested at full speed against a scripted `Runner`, per this project's
  "no live shell-outs in tests" rule. Live-verified once, by hand, against
  this project's own working copy (see the story 1108 handoff): a real
  `just serve` came up on an allocated port and served that commit's actual
  homepage, then `stop_process/1` took it down cleanly.
  """

  @behaviour CmsHarness.AppInstance.Runner

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @pg ~w(-h localhost -U postgres)

  @impl true
  def recipe?(root, name) do
    env = local(root)

    Environments.exec_file_exists?(env, "justfile") and
      case Environments.cmd(env, "just", ["--list"], []) do
        {out, 0} -> Regex.match?(~r/^\s*#{name}(\s|$)/m, out)
        _ -> false
      end
  end

  @impl true
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  @impl true
  def app_name(root), do: Environments.mix_exs_app_name(local(root))

  @impl true
  def database_exists?(database) do
    query = "SELECT 1 FROM pg_database WHERE datname = '#{database}'"

    case System.cmd("psql", @pg ++ ["-tAc", query], stderr_to_stdout: true) do
      {"1" <> _, 0} -> true
      _ -> false
    end
  end

  @impl true
  def main_database_name(root) do
    with main when is_binary(main) <- main_checkout_path(root),
         {:ok, content} <- Environments.read_file(local(main), "config/dev.exs"),
         [_, db] <-
           Regex.run(
             ~r/database:\s*(?:System\.get_env\("DATABASE_NAME"\)\s*\|\|\s*)?"([^"]+)"/,
             content
           ) do
      db
    else
      _ -> nil
    end
  end

  @impl true
  def main_ports(root) do
    with main when is_binary(main) <- main_checkout_path(root),
         {:ok, content} <- Environments.read_file(local(main), "config/dev.exs"),
         http when is_integer(http) <- port_fallback(content, "PORT"),
         https when is_integer(https) <- port_fallback(content, "HTTPS_PORT") do
      {http, https}
    else
      _ -> nil
    end
  end

  defp port_fallback(content, env_var) do
    case Regex.run(
           ~r/port:\s*String\.to_integer\(System\.get_env\("#{env_var}"\)\s*\|\|\s*"(\d+)"\)/,
           content
         ) do
      [_, port] -> String.to_integer(port)
      nil -> nil
    end
  end

  defp main_checkout_path(root) do
    case Environments.cmd(local(root), "git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], []) do
      {out, 0} -> out |> String.trim() |> Path.dirname()
      _ -> nil
    end
  end

  # Dump-and-restore, not `CREATE DATABASE ... TEMPLATE`: main's dev app
  # always holds open connections, and Postgres refuses to template-clone a
  # database that has any. Callers validate both names first
  # (`AppInstance.safe_identifier?/1`) — this never checks again, on the
  # reasoning that a behaviour callback trusts its caller the way any other
  # function here does.
  @impl true
  def clone_database(root, main_database, database) do
    env = local(root)

    with {_out, 0} <- Environments.cmd(env, "createdb", @pg ++ [database], []),
         {out, 0} <-
           Environments.cmd(
             env,
             "bash",
             ["-c", "pg_dump #{Enum.join(@pg, " ")} #{main_database} | psql #{Enum.join(@pg, " ")} -q #{database}"],
             []
           ) do
      _ = out
      :ok
    else
      {out, status} -> {:error, "cloning #{main_database} into #{database} failed (exit #{status}): #{out}"}
    end
  end

  @impl true
  def seed(root) do
    if recipe?(root, "seed"), do: Environments.cmd(local(root), "just", ["seed"], [])
    :ok
  end

  @impl true
  def drop_database(database) do
    System.cmd("dropdb", @pg ++ ["--if-exists", database], stderr_to_stdout: true)
    :ok
  end

  @impl true
  def current_commit(root) do
    case Environments.cmd(local(root), "git", ["rev-parse", "HEAD"], []) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  @impl true
  def run_after_promote(root) do
    case Environments.cmd(local(root), "just", ["after-promote"], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "`just after-promote` failed (#{status}): #{out}"}
    end
  end

  @impl true
  def launch(root, port, https_port, database, log_path, main?, tunnel_held_by_harness?) do
    File.mkdir_p!(Path.dirname(log_path))

    env_prefix =
      "PORT=#{port} HTTPS_PORT=#{https_port} DATABASE_NAME=#{database} " <>
        "CMS_MAIN_COPY=#{main?} CMS_TUNNEL_HELD_BY_HARNESS=#{tunnel_held_by_harness?}"

    cmd = "#{env_prefix} just serve > #{log_path} 2>&1 < /dev/null"

    shell =
      if System.find_executable("setsid") do
        "setsid #{cmd} & echo $!"
      else
        "#{cmd} & disown; echo $!"
      end

    case Environments.cmd(local(root), "bash", ["-c", shell], []) do
      {out, 0} ->
        case out |> String.trim() |> Integer.parse() do
          {os_pid, _} -> {:ok, os_pid}
          :error -> {:error, "no pid on launch: #{inspect(out)}"}
        end

      {out, status} ->
        {:error, "launch exited #{status}: #{String.trim(out)}"}
    end
  end

  @impl true
  def alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  @impl true
  def probe(port) do
    case health_get(port) do
      {:ok, %{status: code}} when code < 500 -> :serving
      {:ok, %{status: _code}} -> :erroring
      _ -> :down
    end
  end

  defp health_get(port) do
    Req.get(
      "http://127.0.0.1:#{port}/",
      [retry: false, receive_timeout: 3_000, connect_options: [timeout: 1_500]] ++ req_plug()
    )
  end

  # Pinnable under test, same reasoning as `Workspaces.Runner.Local.req_plug/0`:
  # the port is an argument, so an unpinned test could probe a real dev
  # server on the machine and read its answer as this instance's health.
  defp req_plug do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  @impl true
  def stop_process(os_pid) do
    System.cmd("pkill", ["-TERM", "-P", Integer.to_string(os_pid)], stderr_to_stdout: true)
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  @impl true
  def listener_pid(port) do
    case System.cmd("lsof", ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-t"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> List.first()
        |> parse_pid()

      _ ->
        nil
    end
  end

  defp parse_pid(nil), do: nil

  defp parse_pid(pid_str) do
    case Integer.parse(pid_str) do
      {pid, _} -> pid
      :error -> nil
    end
  end

  # `ClientUtils.CloudflareTunnel`'s named mode calls `Keyword.fetch!(opts,
  # :endpoint)` / `:otp_app` unconditionally, then uses them to
  # `Application.put_env/3` a Phoenix endpoint's `:url` in *this* process —
  # meaningful when the tunnel runs inside the app's own BEAM, meaningless
  # here, where it runs inside the harness's. There is no real endpoint to
  # configure: the app learns its own public hostname a different way (its
  # own `PREVIEW_HOSTNAME`-from-env config, read at its own boot). A
  # nonexistent app/module pair keeps that write inert rather than reaching
  # for a bare `nil`, which the callee never asked to handle.
  @dummy_otp_app :cms_harness_tunnel
  @dummy_endpoint CmsHarness.NoEndpoint

  # Named and supervised, not a bare linked/unlinked `GenServer.start`: a
  # connector that dies on its own (cloudflared crashing, not `AppInstance`
  # ever asking it to stop) comes back under `restart: :permanent` before the
  # next `ensure_app_running`/`restart_app` push would otherwise have
  # noticed. The name is what makes a second `start_tunnel/2` call for the
  # *same* tunnel find the supervisor-restarted process instead of racing it
  # — `DynamicSupervisor.start_child/2` answers `{:error, {:already_started,
  # pid}}` for a name already registered, and that pid is exactly what
  # `AppInstance` needs to pick back up.
  defp tunnel_via(tunnel_id), do: {:via, Registry, {CmsHarness.Registry, {:tunnel, tunnel_id}}}

  @impl true
  def start_tunnel(credentials, origin_url) do
    child_spec = %{
      id: {:tunnel, credentials.tunnel_id},
      start:
        {ClientUtils.CloudflareTunnel, :start_link,
         [
           [
             mode: :named,
             hostname: credentials.hostname,
             tunnel_id: credentials.tunnel_id,
             account_tag: credentials.account_tag,
             tunnel_secret: credentials.tunnel_secret,
             origin_url: origin_url,
             endpoint: @dummy_endpoint,
             otp_app: @dummy_otp_app,
             name: tunnel_via(credentials.tunnel_id)
           ]
         ]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(CmsHarness.TunnelSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stop_tunnel(pid) do
    # `terminate_child/2`, not `GenServer.stop/1`: a `:permanent` child killed
    # directly is a crash as far as the supervisor is concerned, and it would
    # restart right back — the one outcome a deliberate stop (demoted from
    # main, re-provisioned) must never produce. Removing it from supervision
    # first is what makes the stop actually stick.
    DynamicSupervisor.terminate_child(CmsHarness.TunnelSupervisor, pid)
    :ok
  end

  @impl true
  def process_root(os_pid) do
    case System.cmd("lsof", ["-a", "-p", Integer.to_string(os_pid), "-d", "cwd", "-Fn"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn
          "n" <> path -> path
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp local(root), do: %Environment{type: :local, cwd: root}
end
