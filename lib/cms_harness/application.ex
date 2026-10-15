defmodule CmsHarness.Application do
  @moduledoc """
  The harness's OTP application — what `MIX_ENV=harness` boots, under
  `just harness` in dev and as the installed `cms_harness` release.

  Boots the light harness: no Repo, no local MCP server, no local web UI. It
  watches whichever working copies it is handed, runs analyzers against them,
  and answers hooks — the model and the data both live on the server, reached
  through CmsHarness.Web's proxy.

  The one other thing it boots is `cms migrate` (see `CmsHarness.Migrate`), a
  one-shot import of a local CLI database to the cloud that starts the Repo,
  runs, and halts. It never runs alongside the harness.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CmsHarness.Agents,
      # Installs the harness's log handler.
      CodeMySpec.Logging
    ]

  use Application

  alias CmsHarness.Agents.ProviderTelemetry

  # Burrito.Util.Args is Burrito-release-only — a plain `mix release` doesn't
  # include it. Resolving the module through an atom at runtime keeps both
  # builds clean.
  @burrito_args :"Elixir.Burrito.Util.Args"

  @impl true
  def start(_type, _args) do
    argv = cli_argv()
    remaining = apply_harness_flags(argv)
    handle_cli_args(remaining)

    if CmsHarness.Migrate.command?(remaining) do
      ensure_directories()
      CmsHarness.Migrate.start(remaining)
    else
      start_harness()
    end
  end

  @impl true
  def stop(_state), do: :ok

  defp start_harness do
    harness_log = prepare_host()

    warn_if_no_credential()
    ProviderTelemetry.attach()

    # The endpoint is configured `server: false` so that every *other* way this
    # application boots compiles the harness modules without opening its port.
    # This is the one caller that wants it listening.
    Application.put_env(
      :code_my_spec,
      CmsHarness.Web.Endpoint,
      Application.get_env(:code_my_spec, CmsHarness.Web.Endpoint, [])
      |> Keyword.put(:server, true)
    )

    case Supervisor.start_link([CmsHarness.Supervisor],
           strategy: :one_for_one,
           name: CodeMySpec.Supervisor
         ) do
      {:ok, pid} ->
        # After the supervisor (it starts a subtree under it), before the
        # banner. A no-op unless `CMS_PROJECT_DIR` is set (a sprite).
        CmsHarness.Projects.start_configured()

        print_harness_banner(harness_log)
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  What a harness needs from the machine before it starts, under a service
  supervisor too: the user's toolchain PATH, `~/.codemyspec`, and harness.log.
  Returns the log's path. Also called by `CodeMySpecDesktop.Application`.
  """
  def prepare_host do
    ensure_server_path()
    ensure_directories()
    install_harness_file_logger()
  end

  # Warns and continues: credentials are per working copy
  # (`Credentials.for_working_copy/1`), and a copy with none fails loudly at
  # join (`ChannelClient.unauthorized/2`).
  defp warn_if_no_credential do
    case CmsHarness.Config.credential() do
      {:ok, _} ->
        :ok

      {:error, :no_credential} ->
        IO.puts(:stderr, """

        cms harness: no machine-wide credential. Starting anyway — any
        project whose own .cms_harness.json carries its own deploy_key will
        still connect. A project with neither fails loudly at join time,
        naming itself and the fix.

        To give the whole machine a bootstrap credential instead, set one of:

          config :code_my_spec, harness_token: "…"       # config file
          config :code_my_spec, harness_deploy_key: "…"  # sprite or container
          cms --deploy-key …

        The harness does not read CMS_TOKEN or CMS_DEPLOY_KEY from the
        environment; `mix cms.harness.onboard` does, and records the key in the
        working copy's .cms_harness.json.
        """)

        :ok
    end
  end

  # --deploy-key sets `:harness_deploy_key`, the config `Config.deploy_key/0`
  # reads. --server-url/--node-name are exported as their env vars
  # (CMS_SERVER_URL, CMS_NODE_NAME) for the existing readers.
  # --port sets endpoint config directly: runtime.exs has already read
  # CMS_HARNESS_PORT. Returns the leftover argv for `handle_cli_args/1`.
  defp apply_harness_flags(argv) do
    {opts, rest, _invalid} =
      OptionParser.parse(argv,
        strict: [deploy_key: :string, server_url: :string, port: :string, node_name: :string]
      )

    if key = opts[:deploy_key], do: Application.put_env(:code_my_spec, :harness_deploy_key, key)
    if url = opts[:server_url], do: System.put_env("CMS_SERVER_URL", url)
    if node = opts[:node_name], do: System.put_env("CMS_NODE_NAME", node)

    if port = opts[:port] do
      Application.put_env(
        :code_my_spec,
        CmsHarness.Web.Endpoint,
        Application.get_env(:code_my_spec, CmsHarness.Web.Endpoint, [])
        |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: String.to_integer(port))
      )
    end

    rest
  end

  # Always, alongside stderr: a terminal's scrollback is not a log anyone
  # else can read.
  defp install_harness_file_logger do
    {:ok, path} =
      CodeMySpec.Logging.install_file_handler!(
        source: "harness",
        # The OS pid: ties a line to the banner and `ps`, and tells two
        # harnesses sharing this file apart.
        instance: System.pid(),
        handler_id: :cms_harness_file,
        replace_default: false,
        level: harness_log_level()
      )

    path
  end

  defp harness_log_level do
    case System.get_env("CMS_LOG_LEVEL") do
      level when level in ~w(debug info warning error) -> String.to_existing_atom(level)
      _ -> :info
    end
  end

  defp print_harness_banner(log_path) do
    unless silent?() do
      version = Application.spec(:code_my_spec, :vsn)
      port = Application.get_env(:code_my_spec, CmsHarness.Web.Endpoint)[:http][:port]

      IO.puts(
        "cms harness v#{version}  ·  pid #{System.pid()}  ·  " <>
          "hooks on http://localhost:#{port}  ·  server #{CmsHarness.Config.server_url()}"
      )

      IO.puts("log #{log_path}  ·  CMS_LOG_LEVEL=debug for more")
    end
  end

  defp cli_argv do
    # Only a packaged release parses argv as `cms` subcommands; from source,
    # argv is a mix task's. Mix's presence means "booted from source".
    # `Burrito.Util.Args.argv/0` first when loaded (Burrito rewrites `-extra`),
    # else `System.argv()`.
    if running_under_mix?(), do: [], else: call_optional(@burrito_args, :argv) || System.argv()
  rescue
    _ -> []
  end

  defp running_under_mix?, do: Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0)

  defp handle_cli_args(argv) do
    # Drop Burrito's launcher separator so subcommand matching is clean.
    args = Enum.reject(argv, &(&1 in ["--", ""]))

    cond do
      version_flag?(args) -> print_and_halt(version_string(), 0)
      help_flag?(args) -> print_and_halt(help_text(), 0)
      Enum.any?(["start", "server", "migrate", "harness"], &(&1 in args)) -> :ok
      args == [] -> :ok
      true -> unknown_command(args)
    end
  end

  defp version_flag?(args), do: "--version" in args or "-v" in args
  defp help_flag?(args), do: "--help" in args or "-h" in args

  defp print_and_halt(text, code) do
    IO.puts(text)
    System.halt(code)
  end

  defp unknown_command(args) do
    IO.puts(:stderr, "cms: unknown command #{inspect(hd(args))}\n")
    IO.puts(:stderr, help_text())
    System.halt(2)
  end

  defp version_string do
    version = Application.spec(:code_my_spec, :vsn) |> to_string()
    "cms #{version}"
  end

  defp help_text do
    """
    cms — CodeMySpec light harness

    cms watches whichever working copies it is told to serve, runs analyzers
    against them, and answers hooks and MCP calls by proxying to the server —
    it holds no database and no local web UI of its own. Your workflow
    happens in Claude Code; cms just needs to be running.

    Usage:
      cms start        Run the harness in the foreground (ctrl-C to stop).
                        Serves every checkout whose .cms_harness.json names
                        a project this machine can reach.
      cms migrate --project <cloud-project-id>
                       Copy this checkout's stories, rules, criteria, personas
                       and epics to that project on codemyspec.com. Run it from
                       the project directory. Needs a paid account. The local
                       copy is left alone, and running it again adopts the
                       cloud project rather than making a second.
      cms --version    Print version and exit.
      cms --help       Print this help and exit.

    Flags (all optional; a working copy's own .cms_harness.json deploy_key
    is the normal way one project gets a credential — these aim the whole
    machine instead):
      --deploy-key <key>    Bootstrap credential for projects with no
                             deploy_key of their own yet.
      --server-url <url>    Server to report to. Defaults to codemyspec.com.
      --port <port>         HTTP port for hooks/MCP. Defaults to 4003.
      --node-name <name>    Erlang node name. Only matters when running more
                             than one cms on the same machine.

    Lifecycle is managed by the service supervisor — `brew services` (launchd)
    on macOS, a Shawl-wrapped service on Windows (installed by
    installers/windows/install.ps1). Both run `cms start`, the release
    launcher's foreground boot command. Use those to start/stop/restart and to
    read the service log. Application logs are written to ~/.codemyspec/harness.log.
    """
  end

  defp silent? do
    System.get_env("CMS_QUIET") in ["1", "true"]
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_directories do
    File.mkdir_p!(Path.expand("~/.codemyspec"))
  end

  # A service supervisor (launchd, Shawl) gives a bare PATH without the user's
  # `mix`; recover the user's toolchain PATH so every `System.cmd("mix", …)`
  # resolves. Unix only: Windows services already get the machine PATH.
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

  # Priority order: the user's own shell PATH (their real, working toolchain),
  # the inherited PATH, then common version-manager / Homebrew shim dirs as a
  # last resort. Dedup, preserving order.
  defp unix_toolchain_path do
    segments =
      [user_shell_path(), System.get_env("PATH") | unix_fallback_dirs()]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.flat_map(&String.split(&1, ":", trim: true))
      |> Enum.uniq()

    case segments do
      [] -> nil
      segs -> Enum.join(segs, ":")
    end
  end

  # Bound on the interactive probe, and the fence around its output.
  @path_probe_timeout 5_000
  @path_sentinel "__CMS_PATH__"

  # The interactive PATH: version managers initialise in rc files a login-only
  # shell never sources, and a wrong-OTP `mix` hangs rather than failing. The
  # value is fenced in a sentinel (rc banners print colons) and the probe is
  # bounded; on any failure, fall back to `-lc`.
  defp user_shell_path, do: interactive_shell_path() || login_shell_path()

  defp interactive_shell_path do
    shell = System.get_env("SHELL") || "/bin/sh"
    script = ~s(printf '\\n#{@path_sentinel}%s\\n' "$PATH")

    task = Task.async(fn -> safe_cmd(shell, ["-ilc", script]) end)

    case Task.yield(task, @path_probe_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> extract_fenced_path(out)
      _ -> nil
    end
  end

  defp login_shell_path do
    shell = System.get_env("SHELL") || "/bin/sh"

    case safe_cmd(shell, ["-lc", ~s(printf %s "$PATH")]) do
      {out, 0} -> blank_to_nil(String.trim(out))
      _ -> nil
    end
  end

  # Rescued here: it runs in a linked Task.
  defp safe_cmd(shell, args) do
    System.cmd(shell, args, stderr_to_stdout: false)
  rescue
    _ -> :error
  end

  # Last sentinel line wins: rc output can precede it, never follow it.
  defp extract_fenced_path(out) do
    out
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case String.split(line, @path_sentinel, parts: 2) do
        [_, path] -> blank_to_nil(String.trim(path))
        _ -> nil
      end
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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

  # Dispatch to a module only when it's loaded. Used for the Burrito.Util.Args
  # reference, which doesn't link into every build of this app. Missing module
  # or missing function both resolve to nil.
  defp call_optional(mod, fun, args \\ []) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    end
  end
end
