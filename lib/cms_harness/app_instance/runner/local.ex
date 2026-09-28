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
  def launch(root, port, https_port, database, log_path) do
    File.mkdir_p!(Path.dirname(log_path))

    env_prefix = "PORT=#{port} HTTPS_PORT=#{https_port} DATABASE_NAME=#{database}"
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

  defp local(root), do: %Environment{type: :local, cwd: root}
end
