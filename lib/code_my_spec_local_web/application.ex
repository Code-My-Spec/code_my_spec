defmodule CodeMySpecLocalWeb.Application do
  @moduledoc """
  CLI/local application.

  Boots the light harness: no Repo of its own, no local MCP server, no local
  web UI. It watches whichever working copies it is handed, runs analyzers
  against them, and answers hooks — the model and the data both live on the
  server, reached through CmsHarness.Web's proxy. This is the only thing
  `cms start` boots; there is no flag or env var that reaches anything else.
  """
  use Application

  alias CodeMySpec.Migration
  alias CodeMySpec.Users.Scope

  # Burrito.Util.Args is Burrito-release-only — the bare web build doesn't
  # include it. Resolving the module through an atom at runtime keeps both
  # builds clean.
  @burrito_args :"Elixir.Burrito.Util.Args"

  @impl true
  def start(_type, _args) do
    argv = cli_argv()
    remaining = apply_harness_flags(argv)
    handle_cli_args(remaining)

    cond do
      mcp_relay_command?(remaining) -> start_mcp_relay()
      migrate_command?(remaining) -> start_migrate(remaining)
      true -> start_harness()
    end
  end

  # The only thing this binary boots, `mcp`/`migrate` aside. There is no
  # standalone mode to opt into any more and deliberately no flag that
  # reaches one — a machine either runs the harness or it runs nothing,
  # which is the whole point of shipping one thing. The heavy app's modules
  # (CodeMySpecLocalWeb.Endpoint, its own SQLite Repo, the in-BEAM MCP
  # server) are still compiled into this release — splitting them into a
  # separate OTP app so they stop shipping at all is real, separate work —
  # but nothing in this module calls start_full/1 any more, so nothing here
  # can reach them.
  #
  # --deploy-key/--server-url/--port/--node-name (see apply_harness_flags/1)
  # are CLI-arg spellings of CMS_DEPLOY_KEY/CMS_SERVER_URL/CMS_HARNESS_PORT/
  # CMS_NODE_NAME — a config file per working copy is the real answer for
  # "which project uses which key" (a checkout's own .cms_harness.json can
  # carry its own deploy_key, read per-project at join time), and these
  # exist for the one thing a config file can't do: aim an entire machine's
  # otherwise-unconfigured harness at somewhere other than the compiled
  # default, from the one place — the command that starts it — that both a
  # human and a launchd plist already have to name.
  defp start_harness do
    ensure_server_path()
    ensure_directories()
    harness_log = install_harness_file_logger()

    warn_if_no_credential()

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
        # After the supervisor, because it starts a subtree under it; before the
        # banner, so "serving project X at Y" is above the line announcing the
        # harness is up rather than after it.
        #
        # A no-op unless `CMS_PROJECT_DIR` is set, which is the sprite's case.
        # A laptop leaves it unset and picks working copies up from hooks, which
        # is what every other line of this module assumes.
        CmsHarness.Projects.start_configured()

        # This machine announces itself, once, because the harness came up.
        #
        # Here rather than on a working copy's channel join: one install serves
        # many checkouts, so a per-copy announce would mint a machine per
        # checkout — eight worktrees on this laptop would be eight laptops. And
        # a machine with nothing checked out on it is still a machine, which a
        # join-time announce can never represent.
        #
        # Deliberately not supervised and deliberately not fatal.
        # `Device.announce/0` logs and returns an error if the server cannot be
        # reached, and a harness that cannot announce still watches files, runs
        # analyzers and answers hooks. Refusing to boot over it would trade the
        # whole harness for a gap in a list.
        _ = CmsHarness.Device.announce()

        print_harness_banner(harness_log)
        {:ok, pid}

      other ->
        other
    end
  end

  # One machine, many working copies, and credentials are per-project now:
  # a checkout's own .cms_harness.json can carry its own deploy_key (see
  # CmsHarness.Credentials.for_working_copy/1), read fresh at that project's
  # own join attempt. A machine-wide credential (config, CMS_TOKEN,
  # CMS_DEPLOY_KEY, or --deploy-key below) is one way to bootstrap a project
  # that has not been given its own yet, not a precondition for the harness
  # existing at all — a fresh install with nothing checked out on it yet, or
  # serving only projects that already carry their own key, has no
  # machine-wide credential to offer and nothing wrong with that.
  #
  # So this warns and continues rather than halting. The old rationale for
  # halting — "connected to nothing" reads as alive while refusing every
  # hook, which is worse than not starting — still holds for a project that
  # tries to join and has no credential anywhere, and that failure is still
  # loud: see CmsHarness.Project.ChannelClient.unauthorized/2, which names
  # the project and prints the exact `mix cms.harness.onboard` fix. What
  # changed is only the boot-time check, because boot time is machine-wide
  # and the question it used to ask ("is there a credential") stopped having
  # one true answer per machine.
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
          CMS_TOKEN=…  /  CMS_DEPLOY_KEY=…  / --deploy-key …

        Note that a value in `envs/.env` is NOT enough on its own: Dotenvy loads
        it for `env!/2`, not into the OS environment, so it has to be exported or
        put in config for `System.get_env/1` to see it.
        """)

        :ok
    end
  end

  # CLI-arg spellings of the env vars a machine-wide harness invocation reads.
  # Set the env var and let every existing System.get_env/1 call sites (
  # Config.deploy_key/0, Config.server_url/0, the CMS_HARNESS_PORT read in
  # config/runtime.exs) answer exactly as they already do — a second config
  # surface duplicating that logic is exactly the kind of drift that made
  # tonight's launchd plist edit silently do nothing.
  #
  # runtime.exs's CMS_HARNESS_PORT read already ran by the time this executes
  # (config loads before Application.start/2), so --port takes the config
  # this sets directly rather than through the env var it did not exist in
  # time to be read from.
  # Returns the leftover argv (subcommand words, unrecognized flags) so
  # handle_cli_args/1 still sees exactly what it used to — a flag consumed
  # here must not also fall through to `unknown_command/1`.
  defp apply_harness_flags(argv) do
    {opts, rest, _invalid} =
      OptionParser.parse(argv,
        strict: [deploy_key: :string, server_url: :string, port: :string, node_name: :string]
      )

    if key = opts[:deploy_key], do: System.put_env("CMS_DEPLOY_KEY", key)
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

  # Always, and alongside stderr rather than instead of it.
  #
  # The harness runs in a foreground terminal, so it looked like it had a log —
  # but that terminal belongs to whoever started it, and every question worth
  # asking about a harness gets asked by somebody else. A stop hook refused for
  # an hour with the wrong explanation and the one line naming the real cause
  # existed only in a scrollback nobody could reach.
  defp install_harness_file_logger do
    {:ok, path} =
      CodeMySpec.Logging.install_file_handler!(
        source: "harness",
        # The OS pid, so a line ties back to the startup banner and to `ps`.
        # Two harnesses on one working copy share this file, and until this
        # existed the only sign of the second one was time running backwards.
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

  # `cms migrate --project <cloud-project-id>` copies this checkout's authored
  # graph to the cloud. It needs the database and nothing else — no endpoint,
  # no MCP server — so it boots the same minimum `cms mcp` does plus the Repo,
  # runs once, and halts on the outcome.
  # Env-var fallback for the same reason `cms mcp` has one: a release that is
  # not Burrito-packaged never threads argv through, so the subcommand alone
  # cannot reach this.
  defp migrate_command?(argv) do
    "migrate" in Enum.reject(argv, &(&1 in ["--", ""])) or
      System.get_env("CMS_MIGRATE") in ["1", "true"]
  end

  defp start_migrate(argv) do
    ensure_directories()

    children = [
      CodeMySpec.Vault,
      CodeMySpec.Repo,
      CodeMySpec.Environments.registry_child_spec(),
      CodeMySpecLocalWeb.Migrator
    ]

    {:ok, pid} =
      Supervisor.start_link(children, strategy: :one_for_one, name: CodeMySpec.Supervisor)

    argv |> run_migration() |> report_migration()

    {:ok, pid}
  end

  defp run_migration(argv) do
    with {:ok, cloud_project_id} <- migrate_target(argv),
         working_dir = File.cwd!(),
         {:ok, project} <- CodeMySpec.Projects.resolve_local_project(working_dir),
         {:ok, scope} <- Scope.for_local_project(project, working_dir) do
      IO.puts("Migrating #{project.name} to cloud project #{cloud_project_id}…")

      Migration.Client.migrate(
        scope,
        Keyword.reject([cloud_project_id: cloud_project_id, token: token_override()], fn
          {:token, nil} -> true
          _ -> false
        end)
      )
    end
  end

  # `CMS_TOKEN`, the same override `CmsHarness.Config.user_token/0` already
  # answers to. Without it, `Migration.Client.migrate/2` falls back to
  # `OAuthClient.get_token()` — the token stored locally from whichever
  # server this CLI last logged into, which does not validate against a
  # *different* server (a dev instance has its own signing key and user
  # table; a token minted by one is simply not a token the other issued).
  defp token_override, do: System.get_env("CMS_TOKEN")

  # `--project <id>` names the cloud project to fill. It is deliberately not
  # inferred: the local project's id means nothing on the server, and guessing
  # by name could pour one project's work into another's.
  defp migrate_target(argv) do
    case Enum.drop_while(argv, &(&1 != "--project")) do
      ["--project", id | _] when id != "" -> {:ok, id}
      _ -> project_id_from_env()
    end
  end

  # `CMS_PROJECT_ID` is already this codebase's answer to "which project is
  # this?" — `Projects.resolve_local_project/1` reads it first of all. The
  # cloud keeps the id the project was created with, so the one variable names
  # both ends.
  # `CMS_CLOUD_PROJECT_ID` first: the cloud mints its own id, so it is only by
  # coincidence that it ever equals `CMS_PROJECT_ID` — which names the *local*
  # project to `resolve_local_project/1`. Falling back to it keeps working for
  # anyone whose ids do happen to match.
  defp project_id_from_env do
    case System.get_env("CMS_CLOUD_PROJECT_ID") || System.get_env("CMS_PROJECT_ID") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_project}
    end
  end

  defp report_migration({:ok, summary}) do
    IO.puts("\nMigrated:")

    Enum.each(summary, fn
      {kind, values} when is_list(values) -> IO.puts("  #{kind}: #{Enum.join(values, ", ")}")
      {kind, count} -> IO.puts("  #{kind}: #{count}")
    end)

    IO.puts("\nThe local copy is untouched. The two are independent from here.")
    System.halt(0)
  end

  defp report_migration({:error, :missing_project}),
    do: migration_failed(no_project_message())

  defp report_migration({:error, :cloud_project_id_required}),
    do: migration_failed(no_project_message())

  defp report_migration({:error, {:refused, _status, reason}}),
    do: migration_failed(reason)

  defp report_migration({:error, {:unreachable, reason}}),
    do: migration_failed("could not reach the server: #{inspect(reason)}")

  defp report_migration({:error, reason}), do: migration_failed(inspect(reason))

  defp no_project_message,
    do:
      "name the cloud project — either `cms-migrate --project <cloud-project-id>` " <>
        "or set CMS_CLOUD_PROJECT_ID"

  defp migration_failed(message) do
    IO.puts(:stderr, "\ncms migrate: #{message}")
    IO.puts(:stderr, "Nothing was copied. The local copy is untouched.")
    System.halt(1)
  end

  # `cms mcp` (or CMS_MCP_RELAY=1) boots ONLY the stdio<->server relay — no DB,
  # no endpoint, no banner. Claude Code spawns it and talks MCP over stdio; the
  # relay forwards to the one running `cms server` over HTTP. Env-var fallback
  # covers release invocations that don't thread argv through.
  defp mcp_relay_command?(argv) do
    "mcp" in Enum.reject(argv, &(&1 in ["--", ""])) or
      System.get_env("CMS_MCP_RELAY") in ["1", "true"]
  end

  defp start_mcp_relay do
    base_url =
      System.get_env("CMS_MCP_BASE_URL") ||
        Application.get_env(:code_my_spec, :mcp_relay_base_url, "http://localhost:4004")

    children = [{CodeMySpecCli.McpRelay, base_url: base_url}]
    Supervisor.start_link(children, strategy: :one_for_one, name: CodeMySpec.Supervisor)
  end

  # The standalone app (its own SQLite Repo, CodeMySpecLocalWeb.Endpoint, the
  # in-BEAM MCP server, Migrator, and everything else this used to wire into
  # a Supervisor here) is gone from this path — nothing in `start/2` calls
  # this module's boot code any more, by design: the harness is the only
  # thing this binary boots. The modules themselves are still compiled into
  # the release (splitting them into their own OTP app so they stop shipping
  # as bytes too is separate, real work), but there is deliberately no flag,
  # env var, or subcommand left that reaches them.
  @impl true
  def stop(_state), do: :ok

  defp cli_argv do
    # Only a packaged release gets its argv parsed as `cms` subcommands. Run
    # from source, `System.argv()` holds the mix task name and its flags, and
    # reading it here would reject "cms.content.publish" as an unknown
    # subcommand and halt the VM before the task ran. Mix is absent from the
    # release, which makes its presence the signal for "booted from source."
    #
    # A packaged release still reads through `System.argv()` — it is the
    # `-extra` args the release script's boot line already carries, Burrito or
    # not. `Burrito.Util.Args.argv/0` goes first only because a Burrito build
    # rewrites which args land in `-extra` (unwrapping its own launcher
    # arguments first); the plain `mix release` this ships as today has no
    # such module loaded, and `System.argv()` is exactly what it needs.
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
      subcommand = find_subcommand(args) -> run_subcommand(subcommand, args)
      args == [] -> :ok
      true -> unknown_command(args)
    end
  end

  defp version_flag?(args), do: "--version" in args or "-v" in args
  defp help_flag?(args), do: "--help" in args or "-h" in args

  # Lifecycle (start/stop/restart, logs) is owned by the service supervisor —
  # `brew services` (launchd) on macOS, Shawl on Windows. `cms server` runs the
  # BEAM in the foreground for the supervisor to manage; `start` is kept as a
  # back-compat alias so a service definition still pointing at `cms start`
  # (e.g. an in-flight upgrade with a stale launchd plist) keeps working.
  defp find_subcommand(args) do
    Enum.find(["start", "server", "migrate", "harness"], &(&1 in args))
  end

  defp run_subcommand("start", _args), do: :ok
  defp run_subcommand("server", _args), do: :ok
  # Handled before the full boot, in `start_migrate/1`.
  defp run_subcommand("migrate", _args), do: :ok
  # Handled before the full boot, in `start_harness/0`.
  defp run_subcommand("harness", _args), do: :ok

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
      --port <port>         HTTP port for hooks/MCP. Defaults to 4005.
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

  # The *interactive* PATH is the one that matters. Version managers (asdf,
  # mise, nvm) initialise in `.zshrc`/`.bashrc`, which a login-only `-lc` shell
  # never sources — so their shims arrived only via `unix_fallback_dirs/0`,
  # appended dead last, behind `/opt/homebrew/bin`. A project on a managed
  # Elixir then resolved `mix` to whatever Homebrew had, and a Homebrew Elixir
  # built against a different OTP than the installed one *hangs* rather than
  # failing, wedging every analyzer run at 0% CPU until the job timeout.
  #
  # Reading the user's own PATH also avoids hardcoding a toolchain: someone
  # with no version manager just gets their normal PATH, Homebrew first.
  #
  # `-i` carries the hazards the login-only probe was written to dodge, so both
  # are handled rather than traded away. rc files print banners — one here
  # emitted "Restored session … 18:57:48", whose timestamp colons parsed as
  # PATH separators — so the value is fenced in a sentinel the banner can't
  # forge. And a pathological rc can block without a tty, so the probe is
  # bounded; on timeout, non-zero exit, or missing sentinel we fall back to
  # `-lc`, which is exactly the previous behaviour.
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

  # Runs inside a Task for the interactive probe, so a raise here would take
  # the linked caller down with it — hence the local rescue rather than one
  # around the call site.
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
