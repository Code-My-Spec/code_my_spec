defmodule CodeMySpecLocalWeb.Application do
  @moduledoc """
  CLI/local application.

  Boots with SQLite, local web endpoint, and MCP server.
  No main web endpoint.

  A quick Cloudflare tunnel boots in `:dev_cli` — see `config/dev_cli.exs`.
  """
  use Application

  # CodeMySpecCli.Daemon lives in the sibling CLI project and only links into
  # the CLI binary. The web build compiles this same source without it.
  # Resolving the module through an atom at runtime keeps both builds clean.
  @daemon :"Elixir.CodeMySpecCli.Daemon"

  # Burrito.Util.Args is Burrito-release-only — the bare web build doesn't
  # include it. Same atom trick.
  @burrito_args :"Elixir.Burrito.Util.Args"

  @impl true
  def start(_type, _args) do
    handle_cli_args(cli_argv())

    ensure_server_path()
    ensure_directories()
    maybe_install_file_logger()

    children =
      [
        CodeMySpec.Vault,
        CodeMySpec.Repo,
        CodeMySpec.Environments.registry_child_spec(),
        CodeMySpecLocalWeb.Migrator,
        {Phoenix.PubSub, name: CodeMySpec.PubSub},
        {Task.Supervisor, name: CodeMySpec.Permissions.TaskSupervisor},
        CodeMySpec.Auth.AuthState,
        CodeMySpec.Embeddings.Serving,
        # session_idle_timeout: 4h — agent workflow has long gaps between MCP
        # calls (writing code, running tests, browser automation). The Anubis
        # default of 30 min was dropping the session ~8-10 times per multi-hour
        # session, forcing manual `/mcp` reconnects (-32603 "No active session").
        # 4h covers a normal working block; supervisor restarts re-arm the timer.
        {CodeMySpec.McpServers.LocalServer,
         transport: {:streamable_http, start: true}, session_idle_timeout: to_timeout(hour: 4)},
        CodeMySpecLocalWeb.Endpoint,
        CodeMySpec.ProjectSync.FileWatcherServer,
        CodeMySpecLocalWeb.SocketSupervisor,
        CodeMySpecCli.PresenceClient
      ] ++ tunnel_children()

    opts = [strategy: :one_for_one, name: CodeMySpec.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        daemon_call(:write_pid_file)
        print_server_banner()
        {:ok, pid}

      other ->
        other
    end
  end

  @impl true
  def stop(_state), do: daemon_call(:remove_pid_file)

  # Quick Cloudflare tunnel — :dev_cli only. Config in config/dev_cli.exs.
  defp tunnel_children do
    if Application.get_env(:code_my_spec, :env) == :dev_cli do
      tunnel_config = Application.get_env(:code_my_spec, :cloudflare_tunnel, [])

      tunnel_opts =
        Keyword.merge(tunnel_config,
          endpoint: CodeMySpecLocalWeb.Endpoint,
          otp_app: :code_my_spec,
          origin_url: tunnel_config[:origin_url] || "http://127.0.0.1:4004"
        )

      [{ClientUtils.CloudflareTunnel, tunnel_opts}]
    else
      []
    end
  end

  defp cli_argv do
    call_optional(@burrito_args, :argv) || []
  rescue
    _ -> []
  end

  defp handle_cli_args(argv) do
    # Drop Burrito's launcher separator so subcommand matching is clean.
    args = Enum.reject(argv, &(&1 in ["--", ""]))

    cond do
      version_flag?(args) -> print_and_halt(version_string(), 0)
      help_flag?(args) -> print_and_halt(help_text(), 0)
      subcommand = find_subcommand(args) -> run_subcommand(subcommand, args)
      args == [] -> :ok
      true -> unknown_command(args)
    end
  end

  defp version_flag?(args), do: "--version" in args or "-v" in args
  defp help_flag?(args), do: "--help" in args or "-h" in args

  defp find_subcommand(args) do
    Enum.find(["status", "stop", "logs", "start", "server"], &(&1 in args))
  end

  defp run_subcommand("status", _args), do: System.halt(daemon_call(:print_status))
  defp run_subcommand("stop", _args), do: System.halt(daemon_call(:stop))
  defp run_subcommand("logs", args), do: System.halt(daemon_call(:logs, [follow?(args)]))
  defp run_subcommand("start", _args), do: System.halt(daemon_call(:start, [self_path()]))
  defp run_subcommand("server", _args), do: :ok

  defp follow?(args), do: "-f" in args or "--follow" in args

  defp print_and_halt(text, code) do
    IO.puts(text)
    System.halt(code)
  end

  defp unknown_command(args) do
    IO.puts(:stderr, "cms: unknown command #{inspect(hd(args))}\n")
    IO.puts(:stderr, help_text())
    System.halt(2)
  end

  # Path of the running binary — passed to `start` so the detached child
  # is exactly this binary (Burrito launcher + embedded payload).
  #
  # Burrito's launcher exports `__BURRITO_BIN_PATH`; `get_bin_path/0` reads it
  # and is the only reliable source on Windows. The `$_` / init-args fallbacks
  # are unix shell-isms that yield nothing under the Windows launcher, so
  # without this `self_path` fell back to "cms" — and `cms start` then tried to
  # `Start-Process -FilePath cms` (not on PATH), spawning nothing and timing
  # out on the health check.
  defp self_path do
    burrito_bin_path() ||
      System.get_env("_") ||
      List.first(:init.get_plain_arguments() |> Enum.map(&to_string/1)) ||
      "cms"
  end

  defp burrito_bin_path do
    case call_optional(@burrito_args, :get_bin_path) do
      path when is_binary(path) -> path
      _ -> nil
    end
  end

  defp version_string do
    version = Application.spec(:code_my_spec, :vsn) |> to_string()
    "cms #{version}"
  end

  defp help_text do
    """
    cms — CodeMySpec local server

    The cms process hosts the Phoenix endpoint on :4003 and the MCP server
    the Claude Code plugin talks to. Your workflow happens in Claude Code;
    cms just needs to be running.

    Usage:
      cms start        Start the server in the background, wait for /health.
      cms stop         Stop the running server (SIGTERM, then SIGKILL).
      cms status       Print version/pid/port/log of the running server.
      cms logs         Print the server log.
      cms logs -f      Follow the server log.
      cms server       Run the server in the foreground (ctrl-C to stop).
      cms --version    Print version and exit.
      cms --help       Print this help and exit.

    On Windows, cms runs as a Shawl-wrapped service installed out-of-band by
    installers/windows/install.ps1. Updates are delivered by re-running the
    installer (or the platform install script), not by the binary itself.

    Logs and pid file live in ~/.codemyspec/.
    """
  end

  defp print_server_banner do
    unless silent?() do
      version = Application.spec(:code_my_spec, :vsn)
      pid = System.pid()
      log = daemon_call(:log_file) || Path.expand("~/.codemyspec/server.log")

      IO.puts("cms v#{version}  ·  pid #{pid}  ·  http://localhost:4003  ·  log #{log}")
    end
  end

  defp silent? do
    System.get_env("CMS_QUIET") in ["1", "true"]
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_directories do
    File.mkdir_p!(Path.expand("~/.codemyspec"))
  end

  # Under a service supervisor (macOS launchd via brew, Windows Shawl) the
  # server inherits a bare environment — cwd `/` and a minimal PATH that lacks
  # the user's `mix`/`elixir`. Compile/credo/spex validation then shells out
  # via `System.cmd("mix", ...)` and crashes with :enoent, breaking the
  # stop/subagent-stop hooks. Recover the user's real toolchain PATH at boot
  # and set it on the server process so those lookups resolve. `System.cmd`
  # resolves the executable against the process PATH, so put_env here is what
  # makes every downstream "mix" call work, no matter how cms was launched.
  #
  # Windows services already run with the machine PATH (system-wide Elixir
  # installs land there), so we only do the recovery dance on unix.
  defp ensure_server_path do
    case :os.type() do
      {:unix, _} ->
        case unix_toolchain_path() do
          nil -> :ok
          path -> System.put_env("PATH", path)
        end

      _ ->
        :ok
    end
  end

  # Priority order: the user's login-shell PATH (their real, working
  # toolchain), the inherited PATH, then common version-manager / Homebrew
  # shim dirs as a last resort. Dedup, preserving order.
  defp unix_toolchain_path do
    segments =
      [login_shell_path(), System.get_env("PATH") | unix_fallback_dirs()]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.flat_map(&String.split(&1, ":", trim: true))
      |> Enum.uniq()

    case segments do
      [] -> nil
      segs -> Enum.join(segs, ":")
    end
  end

  # `-lc` (login, non-interactive) loads profile-level config without the
  # job-control/prompt hazards of an interactive `-i` shell, so it can't hang
  # when spawned without a tty. `printf %s "$PATH"` is portable across shells.
  defp login_shell_path do
    shell = System.get_env("SHELL") || "/bin/sh"

    case System.cmd(shell, ["-lc", "printf %s \"$PATH\""], stderr_to_stdout: false) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp unix_fallback_dirs do
    home = System.user_home() || ""

    [
      Path.join(home, ".asdf/shims"),
      Path.join(home, ".local/share/mise/shims"),
      Path.join(home, ".mise/shims"),
      "/opt/homebrew/bin",
      "/usr/local/bin"
    ]
  end

  defp maybe_install_file_logger do
    if Application.get_env(:code_my_spec, :install_file_logger, false) do
      CodeMySpec.Logging.install_file_handler!(source: "server")
    end
  end

  defp daemon_call(fun, args \\ []), do: call_optional(@daemon, fun, args)

  # Dispatch to a module only when it's loaded. Used for cross-project
  # references (CodeMySpecCli.Daemon, Burrito.Util.Args) that don't link
  # into every build of this app. Missing module or missing function both
  # resolve to nil.
  defp call_optional(mod, fun, args \\ []) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    end
  end
end
