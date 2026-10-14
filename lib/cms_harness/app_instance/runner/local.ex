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

  # HTTPS is optional — an app with no HTTPS endpoint declared at all (no
  # `port: String.to_integer(System.get_env("HTTPS_PORT") || ...)` line to
  # match) is a real, ordinary shape, not a malformed config. Requiring both
  # fallbacks here read metric_flow's own `config/dev.exs` (PORT only, no
  # HTTPS_PORT at all) as *no* address resolvable at all —
  # `{:cannot_resolve_main_address, root}` for a checkout whose PORT was
  # right there — because the missing HTTPS half failed the whole `with`.
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

  # Reads the port an endpoint declares in `config/dev.exs` (9320d5c7).
  #
  # This used to match one exact shape —
  # `port: String.to_integer(System.get_env("PORT") || "4000")` — so any other
  # ordinary way of setting a port failed to resolve, and the caller refused
  # with `:cannot_resolve_main_address`: safely, but reading as "this checkout
  # declares no address" when in fact it declares one this could not read. The
  # shapes below are the ones the issue names.
  #
  # Reads `config/dev.exs`, so a `runtime.exs` override is deliberately out of
  # scope: `main_ports/1` is asked what main's *checkout* declares, and the
  # started process reports its own real address elsewhere.
  #
  # An env read with no literal default at all (`System.get_env("PORT")`, no
  # `|| "4000"`) is *also* out of scope, and honestly so: there is no number in
  # the file to read, so no integer can be returned, and inventing one would be
  # worse than the opaque refusal. Closing that case needs the issue's option
  # (1) — read the port off the listening socket, or have it recorded at
  # onboarding — which is the deliberate pass it asks for, not this.
  #
  # Comment lines are skipped: Phoenix's generated dev.exs carries a commented
  # `port: 4001` HTTPS example, which read as main's HTTPS port once nothing
  # else declared one.
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

  Appended, never truncated (c531da1e): a restart launches before the old
  process has exited, and that process still holds the log open without
  `O_APPEND`. Truncating under it left its last write at its old offset — a
  file of NULs with the dying process's "Interrupted by SIGTERM" at the end,
  which read as the new app being killed (181d5fdd).
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

  # `nil` for a main checkout whose `config/dev.exs` declares no HTTPS
  # endpoint at all (`main_ports/1`'s other half of the same fix) — omitted
  # from the launched env entirely rather than interpolated, which would
  # otherwise crash on `nil` having no `String.Chars` implementation.
  defp https_port_env(nil), do: nil
  defp https_port_env(port), do: "HTTPS_PORT=#{port}"

  # `nil` when this copy holds no tunnel (not main, or main with no
  # DB-backed credentials yet — `HarnessProjectChannel.tunnel_for/1`'s own
  # cases) — omitted entirely rather than interpolated, so the app falls
  # back to whatever `PHX_HOST` default it already had, same as today.
  defp host_env(nil), do: nil
  defp host_env(host), do: "PHX_HOST=#{host}"

  @impl true
  def alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  # Harness session, live QA defect on metric_flow: a copy's own
  # `assets/node_modules` was never installed, so its JS bundle built to
  # nothing — no compile error, no boot failure, `GET /` still answers 200.
  # This read as "serving" while every `phx-click` on the page was inert,
  # and QA found it only by hand. `/assets/js/app.js` is Phoenix 1.8's own
  # dev-mode path (unhashed, unlike a prod digest) for exactly the bundle a
  # missing `node_modules` leaves empty or absent — checking it is
  # toolchain-agnostic: it asks "does this URL answer," not "did esbuild
  # print an error."
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

  # `ClientUtils.CloudflareTunnel` defaults `base_dir` (and therefore
  # `config_dir`) to `Path.join(File.cwd!(), "tmp/cloudflared")` — correct
  # for an app writing its own tunnel's config from inside its own checkout,
  # wrong here: one harness BEAM serves every project it is asked about, so
  # its own cwd names none of them in particular. Without this, a harness
  # started from checkout A writing checkout B's tunnel overwrote A's own
  # `config.yml`/`credentials.json` with B's — a real incident (2026-09-29):
  # code_my_spec's own tunnel files were clobbered by metric_flow's, and the
  # only reason `:4000`'s already-running connector kept working is that it
  # had already read its config at its own earlier boot.
  #
  # Never CWD-relative, never inside any checkout: one directory per tunnel,
  # under this machine's own harness state, named by the one thing that
  # never collides between tunnels or changes between restarts.
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
