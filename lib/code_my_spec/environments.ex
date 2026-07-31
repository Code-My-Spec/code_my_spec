defmodule CodeMySpec.Environments do
  @moduledoc """
  Provides execution primitives for running commands and file system operations
  across different execution contexts (server, CLI with tmux, VS Code client).

  This module delegates to specific environment implementations while maintaining
  a consistent interface through the opaque Environment struct.

  Declared as its own Boundary so spex specs can write into the
  in-memory environment they were handed by the case setup. Spex always
  drives the `:memory` adapter (`CodeMySpec.Support.InMemoryEnvironment`),
  so reaching through `Environments.write_file/3` etc. never touches the
  real filesystem.

  ## No environment is a configuration, not a bug

  Every file operation here accepts `nil` and answers instead of raising. That
  is the light harness: the server holds no working copy, so `scope.environment`
  is legitimately nil and there is no disk to reach.

  Until these clauses existed, each of these raised `FunctionClauseError` on the
  way to building an agent's task prompt, and a requirement whose prompt cannot
  be rendered cannot be worked. An agent driving a real project hit it on nine
  requirements in a row — `technical_strategy`, `code_generation`, the four QA
  plans, `release` — and could get no further than a stack trace naming
  `glob/2`, `write_file/3` or `list_directory/2`.

  The answers are the ones callers already handle: `{:error, :no_environment}`
  where a result was expected, `[]` for a search that found nothing reachable,
  `false` for existence. Note the asymmetry that leaves behind — "no disk" and
  "not there" are now the same reply for `file_exists?/2`, which is fine for
  rendering a prompt and is *not* fine for deciding a requirement is unmet. A
  checker that must tell those apart has to say so itself; see
  `CodeMySpec.AgentTasks.Setup.Context.dir_status/2`, which returns
  `:unobservable` rather than pretending to know.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  alias CodeMySpec.Environments.Environment

  @registry __MODULE__.Registry

  @doc """
  Child spec for the environment registry (keyed by project_id).

  Start this in your application supervision tree to enable test-time
  environment overrides. Production projects have no registered override
  and fall back to `Environment.new(:local, project.local_path)`.
  """
  def registry_child_spec do
    {Registry, keys: :unique, name: @registry}
  end

  # OTP/release env vars that, if inherited by a child process, point its
  # `erl` at the parent release's ERTS. The cms CLI ships as a Burrito binary
  # (a self-extracting OTP release) whose `erl` exports these into the OS
  # environment; a child `mix`/`erl` launched against a user's project then
  # resolves its boot files to OUR extracted ERTS
  # (`…/.burrito/code_my_spec_cli_erts-<v>/bin/start.boot`) instead of the
  # user's installed OTP and dies with "cannot get bootfile".
  @otp_release_vars ~w(
    ROOTDIR BINDIR EMU PROGNAME ERL_LIBS
    RELEASE_ROOT RELEASE_SYS_CONFIG RELEASE_TMP RELEASE_NODE RELEASE_VSN
    RELEASE_COOKIE RELEASE_MODE RELEASE_DISTRIBUTION RELEASE_BOOT_SCRIPT
    RELEASE_BOOT_SCRIPT_CLEAN RELEASE_COMMAND RELEASE_PROG RELEASE_NAME
    RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_DISTRIBUTION_FLAG
    ERTS_BIN ERTS_VSN ERLEXEC_DIR ERL_CONSOLE_MODE ELIXIR_VERSION
    REL_VSN_DIR REL_EXEC REL_EXTRA REL_GOTO SCRIPT_PATH
    beforeExtra parsErlang endLoop
  )

  @doc """
  Env entries (`{var, nil}`) that clear the inherited BEAM/release variables,
  for the `:env` option of `System.cmd/3` when shelling out to host tools
  (`mix`, `git`, …) from inside the packaged binary. Clearing lets the child
  derive its own OTP from PATH. Safe off Burrito — clearing an unset var is a
  no-op.
  """
  @spec clean_otp_env() :: [{String.t(), String.t() | nil}]
  def clean_otp_env do
    Enum.map(@otp_release_vars, fn var -> {var, nil} end) ++ path_without_release_dirs()
  end

  # Clearing ROOTDIR is necessary but not sufficient: the release's own
  # `erts-*/bin` is on PATH — *first* under the Windows MSI — so a child
  # `mix`/`elixir` resolves `erl` to OUR erl regardless of what we unset. That
  # erl then derives ROOTDIR from its own location and looks for
  # `<root>/bin/start.boot`, a path no release has (boot files live in
  # `releases/<vsn>/`), so the child dies with "cannot get bootfile" before it
  # ever runs. Every compile, test and credo run on that machine failed this
  # way while the scrub list was working perfectly.
  #
  # Dropping every PATH entry inside RELEASE_ROOT leaves the child resolving
  # the user's own toolchain. Off a release RELEASE_ROOT is unset and PATH is
  # passed through untouched.
  defp path_without_release_dirs do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         path when is_binary(path) <- System.get_env("PATH"),
         sep = path_separator(),
         kept when kept != "" <-
           path
           |> String.split(sep, trim: true)
           |> Enum.reject(&under_root?(&1, root))
           |> Enum.join(sep) do
      [{"PATH", kept}]
    else
      # Not in a release, no PATH, or stripping would empty it — in every case
      # the inherited PATH is the better answer than a broken one.
      _ -> []
    end
  end

  defp path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end

  defp under_root?(entry, root), do: String.starts_with?(normalize(entry), normalize(root))

  # Windows mixes separators and is case-insensitive; unix is neither.
  defp normalize(path) do
    normalized = path |> String.replace("\\", "/") |> String.trim_trailing("/")

    case :os.type() do
      {:win32, _} -> String.downcase(normalized)
      _ -> normalized
    end
  end

  @doc """
  Register an environment override for a project.

  After registration, any caller resolving a scope for `project_id` via
  `lookup_registered/1` gets this env back. Registration is scoped to the
  calling process — when the process exits, the registration is cleared
  automatically (Registry monitors the caller).

  Used by spex test setup to inject in-memory environments without global
  config changes.
  """
  @spec register(any(), Environment.t()) :: :ok
  def register(project_id, %Environment{} = env) do
    case Registry.register(@registry, project_id, env) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  @doc "Unregister a project's environment override. Idempotent."
  @spec unregister(any()) :: :ok
  def unregister(project_id) do
    Registry.unregister(@registry, project_id)
    :ok
  end

  @doc """
  Look up a registered environment override for a project.

  Returns `nil` when no override is registered — the caller should fall
  back to its default env construction.
  """
  @spec lookup_registered(any()) :: Environment.t() | nil
  def lookup_registered(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{_pid, env}] -> env
      [] -> nil
    end
  end

  @doc """
  Create a new execution context and return an opaque Environment struct.

  ## Parameters

  - `type` - Environment type (`:cli`, `:local`, `:vscode`)
  - `opts` - Options passed to the implementation's `create/1` function

  ## Returns

  - `{:ok, %Environment{}}` - Environment created successfully
  - `{:error, reason}` - Failed to create environment

  ## Examples

      # Create CLI environment with tmux
      {:ok, env} = Environments.create(:cli, session_id: 123)

      # Create local environment
      {:ok, env} = Environments.create(:local)
  """
  @spec create(type :: atom(), opts :: keyword()) ::
          {:ok, Environment.t()} | {:error, term()}
  def create(type, opts \\ []) do
    impl(type).create(opts)
  end

  @doc """
  Destroy an execution context and clean up resources.

  This function is idempotent - it should succeed even if the context
  has already been destroyed.
  """
  @spec destroy(env :: Environment.t()) :: :ok | {:error, term()}
  def destroy(%Environment{type: type} = env) do
    impl(type).destroy(env)
  end

  @doc """
  Read a file from the execution environment's file system.
  """
  @spec read_file(env :: Environment.t(), path :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def read_file(nil, _path), do: {:error, :no_environment}

  def read_file(%Environment{type: type} = env, path) do
    impl(type).read_file(env, path)
  end

  @doc """
  List contents of a directory in the execution environment.
  """
  @spec list_directory(env :: Environment.t(), path :: String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_directory(nil, _path), do: {:error, :no_environment}

  def list_directory(%Environment{type: type} = env, path) do
    impl(type).list_directory(env, path)
  end

  @doc """
  Write content to a file in the execution environment's file system.
  """
  @spec write_file(env :: Environment.t(), path :: String.t(), content :: String.t()) ::
          :ok | {:error, term()}
  def write_file(nil, _path, _content), do: {:error, :no_environment}

  def write_file(%Environment{type: type} = env, path, content) do
    impl(type).write_file(env, path, content)
  end

  @doc """
  Delete a file from the execution environment's file system.
  """
  @spec delete_file(env :: Environment.t(), path :: String.t()) ::
          :ok | {:error, term()}
  def delete_file(nil, _path), do: {:error, :no_environment}

  def delete_file(%Environment{type: type} = env, path) do
    impl(type).delete_file(env, path)
  end

  # Private functions

  defp impl(:cli),
    do: Application.get_env(:code_my_spec, :environment, CodeMySpec.Environments.Cli)

  defp impl(:vscode),
    do: Application.get_env(:code_my_spec, :environment, CodeMySpec.Environments.VSCode)

  defp impl(:local),
    do: Application.get_env(:code_my_spec, :environment, CodeMySpec.Environments.Local)

  defp impl(:memory), do: CodeMySpec.Support.InMemoryEnvironment

  # No `:server` clause and no catch-all on purpose. `Environment.type` is
  # `Ecto.Enum, values: [:cli, :local, :vscode]`, so neither was reachable —
  # and both returned an `{:error, _}` tuple where every caller immediately
  # does `impl(type).some_function(...)`, which would have crashed with
  # "tuple.some_function/N is undefined" rather than surfacing the error.
  # An unknown type now raises FunctionClauseError, naming the real problem.

  def environment_setup_command(environment, attrs) do
    impl(environment).environment_setup_command(environment, attrs)
  end

  def docs_environment_teardown_command(environment, attrs) do
    impl(environment).docs_environment_teardown_command(environment, attrs)
  end

  def test_environment_teardown_command(environment, attrs) do
    impl(environment).test_environment_teardown_command(environment, attrs)
  end

  def code_environment_teardown_command(environment, attrs) do
    impl(environment).code_environment_teardown_command(environment, attrs)
  end

  def file_exists?(nil, _path), do: false

  def file_exists?(%Environment{type: type} = env, path) do
    impl(type).file_exists?(env, path)
  end

  @doc """
  Stat a file, returning its mtime and size.
  """
  @spec stat(env :: Environment.t(), path :: String.t()) ::
          {:ok, %{mtime: DateTime.t(), size: non_neg_integer()}} | {:error, term()}
  def stat(nil, _path), do: {:error, :no_environment}

  def stat(%Environment{type: type} = env, path) do
    impl(type).stat(env, path)
  end

  @doc """
  Ensure a directory exists, creating it and any parents if needed.
  """
  @spec ensure_dir(env :: Environment.t(), path :: String.t()) :: :ok | {:error, term()}
  def ensure_dir(nil, _path), do: {:error, :no_environment}

  def ensure_dir(%Environment{type: type} = env, path) do
    impl(type).ensure_dir(env, path)
  end

  @doc """
  Find files matching a glob pattern relative to the environment's working directory.
  """
  @spec glob(env :: Environment.t(), pattern :: String.t()) :: [String.t()]
  def glob(nil, _pattern), do: []

  def glob(%Environment{type: type} = env, pattern) do
    impl(type).glob(env, pattern)
  end

  @doc """
  Stream files under a whitelisted set of roots, pruning to those subtrees only.

  Roots are resolved relative to `env.cwd`; missing roots are skipped. Emitted
  paths are relative to `env.cwd`.
  """
  @spec stream_files(env :: Environment.t(), roots :: [String.t()], opts :: keyword()) ::
          Enumerable.t()
  def stream_files(env, roots, opts \\ [])

  def stream_files(nil, _roots, _opts), do: []

  def stream_files(%Environment{type: type} = env, roots, opts) do
    impl(type).stream_files(env, roots, opts)
  end

  @doc """
  Run a command in the environment.

  Defaults to `env.cwd`; pass `:cd` to override. See
  `c:CodeMySpec.Environments.EnvironmentsBehaviour.cmd/4`.
  """
  @spec cmd(Environment.t(), String.t(), [String.t()], keyword()) ::
          {String.t(), non_neg_integer()}
  def cmd(env, command, args, opts \\ [])

  def cmd(nil, _command, _args, _opts), do: {"no environment", 1}

  def cmd(%Environment{type: type} = env, command, args, opts),
    do: impl(type).cmd(env, command, args, opts)

  @doc """
  Whether `path` exists in the filesystem `cmd/4` runs in.

  See `c:CodeMySpec.Environments.EnvironmentsBehaviour.exec_file_exists?/2` for
  why this is not `file_exists?/2`.
  """
  @spec exec_file_exists?(Environment.t(), String.t()) :: boolean()
  def exec_file_exists?(nil, _path), do: false

  def exec_file_exists?(%Environment{type: type} = env, path),
    do: impl(type).exec_file_exists?(env, path)
end
