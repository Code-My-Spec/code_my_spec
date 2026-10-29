defmodule CodeMySpec.ExecutionContexts do
  @moduledoc """
  Execution primitives — commands and file operations — over an opaque
  `ExecutionContext`, delegating to the implementation for its type (`:cli`,
  `:local`, `:container`, `:harness`, `:memory`).

  Its own Boundary so spex can write into the `:memory` execution context
  (`CodeMySpec.Support.InMemoryExecutionContext`) the case setup handed them.

  ## An absent execution context is valid

  Every file operation accepts `nil` (the server has no local working copy) and
  answers instead of raising: `{:error, :no_environment}` where a result was
  expected, `[]` for a search, `false` for existence. So "no disk" and "not
  there" are the same reply for `file_exists?/2` — fine for rendering a prompt,
  not for deciding a requirement is unmet; use `unobservable?/1` or
  `CodeMySpec.AgentTasks.Setup.Context.dir_status/2` for that.
  See knowledge/infrastructure, "Execution contexts".
  """

  use Boundary, top_level?: true, deps: [CodeMySpec.DurableRun], exports: :all

  alias CodeMySpec.ExecutionContexts.ExecutionContext

  @registry __MODULE__.Registry

  @doc """
  Child spec for the execution-context registry (keyed by project_id).

  Start this in your application supervision tree to enable execution-context
  overrides. Callers choose the registry key (for example a working-copy id
  or root); this registry does not select a working copy or supply a fallback.
  """
  def registry_child_spec do
    {Registry, keys: :unique, name: @registry}
  end

  @doc """
  Whether an error means "could not look" rather than "not there".

  A checker that flattens these into a requirement failure tells an agent to
  redo work that is very likely already done.
  """
  @spec unobservable?(term()) :: boolean()
  def unobservable?(:no_environment), do: true
  def unobservable?({:error, reason}), do: unobservable?(reason)
  def unobservable?(_), do: false

  # Release vars that, inherited, point a child `erl` at our ERTS ("cannot get
  # bootfile"). See knowledge/infrastructure, "Child process environment".
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

  # Our Mix environment would change which of the child project's deps exist.
  # Separate from the release vars because a caller may choose the child's
  # (`merge_clean_env/1` lets an explicit `:env` entry win).
  @mix_env_vars ~w(MIX_ENV MIX_TARGET MIX_BUILD_PATH MIX_DEPS_PATH MIX_HOME MIX_ARCHIVES)

  @doc """
  Env entries (`{var, nil}`) that clear the inherited BEAM/release variables,
  for the `:env` option of `System.cmd/3` when shelling out to host tools
  (`mix`, `git`, …) from inside the packaged binary. Clearing lets the child
  derive its own OTP from PATH. Safe off Burrito — clearing an unset var is a
  no-op.
  """
  @spec clean_otp_env() :: [{String.t(), String.t() | nil}]
  def clean_otp_env do
    Enum.map(@otp_release_vars ++ @mix_env_vars, fn var -> {var, nil} end) ++
      path_without_release_dirs()
  end

  # Version-manager shims first, so a child resolves the toolchain its own
  # directory pins rather than ours. Only for `merge_clean_env/1`, never
  # `clean_otp_env/0`, which is a scrub and adds nothing.
  # See knowledge/infrastructure, "Child process environment".
  defp path_for_children do
    case path_without_release_dirs() do
      [{"PATH", path}] -> [{"PATH", prepend_shims(path)}]
      [] -> shim_path_entry()
    end
  end

  defp shim_path_entry do
    case System.get_env("PATH") do
      path when is_binary(path) -> [{"PATH", prepend_shims(path)}]
      _ -> []
    end
  end

  # asdf and mise, only where the directory exists. **Moved** to the front, not
  # added: the shims are usually on PATH already, behind the resolved bin dir.
  defp prepend_shims(path) do
    sep = path_separator()
    existing = String.split(path, sep, trim: true)

    shims =
      ["~/.asdf/shims", "~/.local/share/mise/shims"]
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)

    Enum.join(shims ++ (existing -- shims), sep)
  end

  @doc """
  `clean_otp_env/0` with the caller's own `:env` entries left standing.

  The scrub is appended last so it wins, which is right for the release
  variables — no caller sets those, and a child that inherits them cannot
  boot. It is wrong for `MIX_ENV`: a caller that named one meant it.
  """
  @spec merge_clean_env(keyword()) :: keyword()
  def merge_clean_env(opts) do
    chosen = opts |> Keyword.get(:env, []) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    # String keys, so not a keyword list despite the shape — `Keyword.delete/2`
    # raises on one.
    scrub =
      clean_otp_env()
      |> Enum.reject(&(elem(&1, 0) == "PATH"))
      |> Kernel.++(path_for_children())
      |> Enum.reject(&MapSet.member?(chosen, elem(&1, 0)))

    Keyword.update(opts, :env, scrub, &(&1 ++ scrub))
  end

  # Clearing ROOTDIR is not enough: the release's `erts-*/bin` is on PATH, so a
  # child would still find our `erl`. Drop every PATH entry inside RELEASE_ROOT;
  # off a release PATH passes through untouched.
  # See knowledge/infrastructure, "Child process environment".
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
  @spec register(any(), ExecutionContext.t()) :: :ok
  def register(project_id, %ExecutionContext{} = env) do
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

  Also `nil` when the registry itself is not running (a caller outside a
  started application, such as a mix task that starts only `:req`), so the
  caller reports the absence in its own words.
  """
  @spec lookup_registered(any()) :: ExecutionContext.t() | nil
  def lookup_registered(project_id) do
    if running?(@registry), do: registered(project_id), else: nil
  end

  defp registered(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{_pid, env}] -> env
      [] -> nil
    end
  end

  # Asked, not rescued: a rescue cannot tell "not running" from any other
  # `ArgumentError`, such as a wrong registry name.
  defp running?(registry), do: is_pid(Process.whereis(registry))

  @doc """
  Create a new execution context and return an opaque ExecutionContext struct.

  ## Parameters

  - `type` - ExecutionContext type (`:cli`, `:local`, `:container`)
  - `opts` - Options passed to the implementation's `create/1` function

  ## Returns

  - `{:ok, %ExecutionContext{}}` - ExecutionContext created successfully
  - `{:error, reason}` - Failed to create environment

  ## Examples

      # Create CLI environment
      {:ok, env} = ExecutionContexts.create(:cli, session_id: 123)

      # Create local environment
      {:ok, env} = ExecutionContexts.create(:local)
  """
  @spec create(type :: atom(), opts :: keyword()) ::
          {:ok, ExecutionContext.t()} | {:error, term()}
  def create(type, opts \\ []) do
    impl(type).create(opts)
  end

  @doc """
  Destroy an execution context and clean up resources.

  This function is idempotent - it should succeed even if the context
  has already been destroyed.
  """
  @spec destroy(env :: ExecutionContext.t()) :: :ok | {:error, term()}
  def destroy(%ExecutionContext{type: type} = env) do
    impl(type).destroy(env)
  end

  @doc """
  Read a file from the execution environment's file system.
  """
  @spec read_file(env :: ExecutionContext.t(), path :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def read_file(nil, _path), do: {:error, :no_environment}

  def read_file(%ExecutionContext{type: type} = env, path) do
    impl(type).read_file(env, path)
  end

  @doc """
  The real OTP app name for this environment's checkout, read straight out of
  its `mix.exs` — the one place it is never ambiguous, since it is what `mix
  release` and `mix phx.gen` themselves resolve every `lib/<app>(_web)/...`
  path from.

  `nil` when `mix.exs` cannot be read (no environment, or one server-side code
  cannot reach) or does not contain a plain `app: :name` — a clean absence to
  fall back from, not a wrong guess.
  """
  @spec mix_exs_app_name(env :: ExecutionContext.t() | nil) :: String.t() | nil
  def mix_exs_app_name(env) do
    with {:ok, content} <- read_file(env, "mix.exs"),
         [_, app] <- Regex.run(~r/app:\s*:([a-zA-Z_][a-zA-Z0-9_]*)/, content) do
      app
    else
      _ -> nil
    end
  end

  @doc """
  List contents of a directory in the execution environment.
  """
  @spec list_directory(env :: ExecutionContext.t(), path :: String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_directory(nil, _path), do: {:error, :no_environment}

  def list_directory(%ExecutionContext{type: type} = env, path) do
    impl(type).list_directory(env, path)
  end

  @doc """
  Write content to a file in the execution environment's file system.
  """
  @spec write_file(env :: ExecutionContext.t(), path :: String.t(), content :: String.t()) ::
          :ok | {:error, term()}
  def write_file(nil, _path, _content), do: {:error, :no_environment}

  def write_file(%ExecutionContext{type: type} = env, path, content) do
    impl(type).write_file(env, path, content)
  end

  @doc """
  Delete a file from the execution environment's file system.
  """
  @spec delete_file(env :: ExecutionContext.t(), path :: String.t()) ::
          :ok | {:error, term()}
  def delete_file(nil, _path), do: {:error, :no_environment}

  def delete_file(%ExecutionContext{type: type} = env, path) do
    impl(type).delete_file(env, path)
  end

  @doc """
  The recorded analyzer output `env` carries for `source`, if any.

  See `c:CodeMySpec.ExecutionContexts.ExecutionContextsBehaviour.recorded_output/2`.
  """
  @spec recorded_output(ExecutionContext.t() | nil, String.t()) :: String.t() | nil
  def recorded_output(%ExecutionContext{type: type} = env, source) do
    module = impl(type)

    if Code.ensure_loaded?(module) and function_exported?(module, :recorded_output, 2),
      do: module.recorded_output(env, source)
  end

  def recorded_output(_env, _source), do: nil

  # Private functions

  defp impl(:cli),
    do:
      Application.get_env(
        :code_my_spec,
        :execution_context_adapter,
        CodeMySpec.ExecutionContexts.Cli
      )

  defp impl(:local),
    do:
      Application.get_env(
        :code_my_spec,
        :execution_context_adapter,
        CodeMySpec.ExecutionContexts.Local
      )

  defp impl(:container),
    do:
      Application.get_env(
        :code_my_spec,
        :container_execution_context_adapter,
        CodeMySpec.ExecutionContexts.Container
      )

  defp impl(:memory), do: CodeMySpec.Support.InMemoryExecutionContext

  # A working copy on another machine, reached over its harness channel. Not
  # configurable like the others: there is no alternative implementation of
  # "ask the harness", and swapping it would mean swapping the transport.
  defp impl(:harness), do: CodeMySpec.ExecutionContexts.Harness

  # No catch-all on purpose: an unknown type raises FunctionClauseError, which
  # names the problem, where an `{:error, _}` here would crash the caller's
  # `impl(type).fun(...)` with a confusing undefined-function error.

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

  def file_exists?(%ExecutionContext{type: type} = env, path) do
    impl(type).file_exists?(env, path)
  end

  @doc """
  Stat a file, returning its mtime and size.
  """
  @spec stat(env :: ExecutionContext.t(), path :: String.t()) ::
          {:ok, %{mtime: DateTime.t(), size: non_neg_integer()}} | {:error, term()}
  def stat(nil, _path), do: {:error, :no_environment}

  def stat(%ExecutionContext{type: type} = env, path) do
    impl(type).stat(env, path)
  end

  @doc """
  Ensure a directory exists, creating it and any parents if needed.
  """
  @spec ensure_dir(env :: ExecutionContext.t(), path :: String.t()) :: :ok | {:error, term()}
  def ensure_dir(nil, _path), do: {:error, :no_environment}

  def ensure_dir(%ExecutionContext{type: type} = env, path) do
    impl(type).ensure_dir(env, path)
  end

  @doc """
  Find files matching a glob pattern relative to the environment's working directory.
  """
  @spec glob(env :: ExecutionContext.t(), pattern :: String.t()) :: [String.t()]
  def glob(nil, _pattern), do: []

  def glob(%ExecutionContext{type: type} = env, pattern) do
    impl(type).glob(env, pattern)
  end

  @doc """
  Stream files under a whitelisted set of roots, pruning to those subtrees only.

  Roots are resolved relative to `env.cwd`; missing roots are skipped. Emitted
  paths are relative to `env.cwd`.
  """
  @spec stream_files(env :: ExecutionContext.t(), roots :: [String.t()], opts :: keyword()) ::
          Enumerable.t()
  def stream_files(env, roots, opts \\ [])

  def stream_files(nil, _roots, _opts), do: []

  def stream_files(%ExecutionContext{type: type} = env, roots, opts) do
    impl(type).stream_files(env, roots, opts)
  end

  @doc """
  Run a command in the environment.

  Defaults to `env.cwd`; pass `:cd` to override. See
  `c:CodeMySpec.ExecutionContexts.ExecutionContextsBehaviour.cmd/4`.
  """
  @spec cmd(ExecutionContext.t(), String.t(), [String.t()], keyword()) ::
          {String.t(), non_neg_integer()}
  def cmd(env, command, args, opts \\ [])

  def cmd(nil, _command, _args, _opts), do: {"no environment", 1}

  def cmd(%ExecutionContext{type: type} = env, command, args, opts),
    do: impl(type).cmd(env, command, args, opts)

  @doc """
  Whether `path` exists in the filesystem `cmd/4` runs in.

  See `c:CodeMySpec.ExecutionContexts.ExecutionContextsBehaviour.exec_file_exists?/2` for
  why this is not `file_exists?/2`.
  """
  @spec exec_file_exists?(ExecutionContext.t(), String.t()) :: boolean()
  def exec_file_exists?(nil, _path), do: false

  def exec_file_exists?(%ExecutionContext{type: type} = env, path),
    do: impl(type).exec_file_exists?(env, path)

  @doc """
  Whether the project's justfile declares the recipe `name`.

  How a project runs its own suites is the project's to say: a runner that
  finds `spex` or `test` here runs `just <name> …` instead of `mix <name> …`,
  with the same arguments, so the recipe must pass them through.
  """
  @spec recipe?(ExecutionContext.t() | nil, String.t()) :: boolean()
  def recipe?(env, name) do
    exec_file_exists?(env, "justfile") and
      case cmd(env, "just", ["--list"], []) do
        {out, 0} -> Regex.match?(~r/^\s*#{Regex.escape(name)}(\s|$)/m, out)
        _ -> false
      end
  end
end
