defmodule CmsHarness.AppInstance.Runner.Local do
  @moduledoc """
  The real thing: `just`, `psql`, `pg_dump`, a real detached OS process.

  Kept apart from `CmsHarness.AppInstance` so the orchestration is tested
  against a scripted `Runner` and tests never shell out.
  """

  @behaviour CmsHarness.AppInstance.Runner

  require Logger

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @pg ~w(-h localhost -U postgres)

  @impl true
  def recipe?(root, name), do: Environments.recipe?(local(root), name)

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

  # HTTPS is optional: an app with no HTTPS endpoint is an ordinary shape, and
  # must not fail the whole lookup.
  @impl true
  def main_ports(root) do
    with main when is_binary(main) <- main_checkout_path(root),
         {:ok, content} <- Environments.read_file(local(main), "config/dev.exs"),
         http when is_integer(http) <- declared_port(content, "PORT") do
      {http, declared_port(content, "HTTPS_PORT")}
    else
      _ -> nil
    end
  end

  # Reads the port an endpoint declares in `config/dev.exs`: an env read with a
  # literal default, or a literal. Out of scope: `runtime.exs` overrides, and an
  # env read with no default (there is no number to read; never invent one).
  # Comment lines are skipped (Phoenix's dev.exs has a commented HTTPS example).
  def declared_port(content, env_var) do
    content = uncommented(content)
    env_port(content, env_var) || literal_port(content)
  end

  defp uncommented(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
    |> Enum.join("\n")
  end

  # The original shape, and any env-var name: the variable must be the one
  # asked for, and the default is the port.
  defp env_port(content, env_var) do
    case Regex.run(
           ~r/port:\s*String\.to_integer\(System\.get_env\("#{Regex.escape(env_var)}"\)\s*\|\|\s*"(\d+)"\)/,
           content
         ) do
      [_, port] -> String.to_integer(port)
      nil -> nil
    end
  end

  # A literal: `port: 4567`. Bounded so it cannot pick up a number from a URL
  # or from an option that merely ends in a digit.
  defp literal_port(content) do
    case Regex.run(~r/port:\s*(\d{2,5})\s*[,}\]]/, content) do
      [_, port] -> String.to_integer(port)
      nil -> nil
    end
  end

  defp main_checkout_path(root) do
    case Environments.cmd(
           local(root),
           "git",
           ["rev-parse", "--path-format=absolute", "--git-common-dir"],
           []
         ) do
      {out, 0} -> out |> String.trim() |> Path.dirname()
      _ -> nil
    end
  end

  # Dump-and-restore, not `TEMPLATE`: Postgres refuses to template-clone a
  # database with open connections, and main's app always has some. Callers
  # validate both names (`AppInstance.safe_identifier?/1`).
  @impl true
  def clone_database(root, main_database, database) do
    env = local(root)

    with {_out, 0} <- Environments.cmd(env, "createdb", @pg ++ [database], []),
         {out, 0} <-
           Environments.cmd(
             env,
             "bash",
             [
               "-c",
               "pg_dump #{Enum.join(@pg, " ")} #{main_database} | psql #{Enum.join(@pg, " ")} -q #{database}"
             ],
             []
           ) do
      _ = out
      :ok
    else
      {out, status} ->
        {:error, "cloning #{main_database} into #{database} failed (exit #{status}): #{out}"}
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
  def launch(
        root,
        port,
        https_port,
        database,
        log_path,
        main?,
        tunnel_held_by_harness?,
        host \\ nil
      ) do
    File.mkdir_p!(Path.dirname(log_path))

    env_prefix =
      [
        "PORT=#{port}",
        https_port_env(https_port),
        "DATABASE_NAME=#{database}",
        "CMS_MAIN_COPY=#{main?}",
        "CMS_TUNNEL_HELD_BY_HARNESS=#{tunnel_held_by_harness?}",
        host_env(host)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    cmd = serve_command(env_prefix, log_path)

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

  @doc """
  The `just serve` line `launch/8` backgrounds, output appended to `log_path`.

  Appended, never truncated: the old process may still hold the log open
  without `O_APPEND`, and truncating under it leaves NULs and its dying words,
  which read as the new app being killed.
  """
  @spec serve_command(String.t(), String.t()) :: String.t()
  def serve_command(env_prefix, log_path),
    do: "#{env_prefix} just serve >> #{log_path} 2>&1 < /dev/null"

  # In the foreground, unlike `launch/8`: the recipe ends once the running app
  # has migrated, compiled and answered, and its exit status is the verdict.
  # Output goes to the app's own log, beside what `serve` wrote there.
  @impl true
  def reload(root, port, https_port, database, log_path) do
    env =
      [{"PORT", to_string(port)}, {"DATABASE_NAME", database}] ++
        if(https_port, do: [{"HTTPS_PORT", to_string(https_port)}], else: [])

    {out, status} =
      Environments.cmd(local(root), "just", ["reload"], env: env, stderr_to_stdout: true)

    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "\n--- just reload ---\n" <> out, [:append])

    case status do
      0 ->
        :ok

      _ ->
        {:error,
         "`just reload` failed (#{status}): #{out |> String.trim() |> String.slice(-2000, 2000)}"}
    end
  end

  # Omitted from the env when there is no HTTPS endpoint.
  defp https_port_env(nil), do: nil
  defp https_port_env(port), do: "HTTPS_PORT=#{port}"

  # Omitted when this copy holds no tunnel, so the app keeps its own default.
  defp host_env(nil), do: nil
  defp host_env(host), do: "PHX_HOST=#{host}"

  @impl true
  def alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  # Also checks the JS bundle (`/assets/js/app.js`, Phoenix's dev path): a
  # missing `node_modules` builds it empty while `GET /` still answers 200.
  @impl true
  def probe(port) do
    case health_get(port) do
      {:ok, %{status: code}} when code < 500 -> js_bundle_probe(port)
      {:ok, %{status: _code}} -> :erroring
      _ -> :down
    end
  end

  defp js_bundle_probe(port) do
    case js_bundle_get(port) do
      {:ok, %{status: 200}} ->
        :serving

      _ ->
        Logger.warning(
          "[CmsHarness] #{port} is up but its JS bundle is not served " <>
            "(assets never built) — reporting erroring, not serving"
        )

        :erroring
    end
  end

  defp health_get(port) do
    Req.get(
      "http://127.0.0.1:#{port}/",
      [retry: false, receive_timeout: 3_000, connect_options: [timeout: 1_500]] ++ req_plug()
    )
  end

  defp js_bundle_get(port) do
    Req.get(
      "http://127.0.0.1:#{port}/assets/js/app.js",
      [retry: false, receive_timeout: 3_000, connect_options: [timeout: 1_500]] ++ req_plug()
    )
  end

  # Pinnable under test, so a test never probes a real dev server.
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
    case System.cmd("lsof", ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-t"],
           stderr_to_stdout: true
         ) do
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

  # `ClientUtils.CloudflareTunnel` requires `:endpoint`/`:otp_app` and writes an
  # endpoint `:url` into this BEAM; a nonexistent pair keeps that write inert.
  @dummy_otp_app :cms_harness_tunnel
  @dummy_endpoint CmsHarness.NoEndpoint

  # Named and supervised (`restart: :permanent`): a connector that dies comes
  # back on its own, and a second `start_tunnel/2` for the same tunnel gets
  # the running pid via `{:already_started, pid}`.
  defp tunnel_via(tunnel_id), do: {:via, Registry, {CmsHarness.Registry, {:tunnel, tunnel_id}}}

  # One directory per tunnel id under harness state, never cwd-relative: the
  # library's default (`cwd/tmp/cloudflared`) let one project's tunnel
  # overwrite another's config.
  @doc false
  def tunnel_base_dir(tunnel_id) do
    Path.join([System.user_home!(), ".codemyspec", "tunnels", tunnel_id])
  end

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
             name: tunnel_via(credentials.tunnel_id),
             base_dir: tunnel_base_dir(credentials.tunnel_id)
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
    # `terminate_child/2`, not `GenServer.stop/1`: a `:permanent` child stopped
    # directly would be restarted.
    DynamicSupervisor.terminate_child(CmsHarness.TunnelSupervisor, pid)
    :ok
  end

  @impl true
  def process_root(os_pid) do
    case System.cmd("lsof", ["-a", "-p", Integer.to_string(os_pid), "-d", "cwd", "-Fn"],
           stderr_to_stdout: true
         ) do
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
