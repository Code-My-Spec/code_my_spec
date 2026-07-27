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
  )

  @doc """
  Env entries (`{var, nil}`) that clear the inherited BEAM/release variables,
  for the `:env` option of `System.cmd/3` when shelling out to host tools
  (`mix`, `git`, …) from inside the packaged binary. Clearing lets the child
  derive its own OTP from PATH. Safe off Burrito — clearing an unset var is a
  no-op.
  """
  @spec clean_otp_env() :: [{String.t(), nil}]
  def clean_otp_env, do: Enum.map(@otp_release_vars, fn var -> {var, nil} end)

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
  def read_file(%Environment{type: type} = env, path) do
    impl(type).read_file(env, path)
  end

  @doc """
  List contents of a directory in the execution environment.
  """
  @spec list_directory(env :: Environment.t(), path :: String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_directory(%Environment{type: type} = env, path) do
    impl(type).list_directory(env, path)
  end

  @doc """
  Write content to a file in the execution environment's file system.
  """
  @spec write_file(env :: Environment.t(), path :: String.t(), content :: String.t()) ::
          :ok | {:error, term()}
  def write_file(%Environment{type: type} = env, path, content) do
    impl(type).write_file(env, path, content)
  end

  @doc """
  Delete a file from the execution environment's file system.
  """
  @spec delete_file(env :: Environment.t(), path :: String.t()) ::
          :ok | {:error, term()}
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

  def file_exists?(%Environment{type: type} = env, path) do
    impl(type).file_exists?(env, path)
  end

  @doc """
  Stat a file, returning its mtime and size.
  """
  @spec stat(env :: Environment.t(), path :: String.t()) ::
          {:ok, %{mtime: DateTime.t(), size: non_neg_integer()}} | {:error, term()}
  def stat(%Environment{type: type} = env, path) do
    impl(type).stat(env, path)
  end

  @doc """
  Ensure a directory exists, creating it and any parents if needed.
  """
  @spec ensure_dir(env :: Environment.t(), path :: String.t()) :: :ok | {:error, term()}
  def ensure_dir(%Environment{type: type} = env, path) do
    impl(type).ensure_dir(env, path)
  end

  @doc """
  Find files matching a glob pattern relative to the environment's working directory.
  """
  @spec glob(env :: Environment.t(), pattern :: String.t()) :: [String.t()]
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
  def stream_files(%Environment{type: type} = env, roots, opts \\ []) do
    impl(type).stream_files(env, roots, opts)
  end

  def cmd(environment, command, args, opts \\ []),
    do: impl(environment).cmd(command, args, opts)
end
