defmodule CodeMySpec.ExecutionContexts.ExecutionContextsBehaviour do
  @moduledoc """
  Behaviour for execution-context implementations.

  Execution contexts define HOW commands execute (not WHAT commands to generate).
  Each implementation handles execution in its own context (local filesystem,
  container, a remote harness, in-memory for tests).
  """

  alias CodeMySpec.ExecutionContexts.ExecutionContext

  @doc """
  Create an execution environment.

  Returns an ExecutionContext struct containing implementation-specific references.
  """
  @callback create(opts :: keyword()) :: {:ok, ExecutionContext.t()} | {:error, term()}

  @doc """
  Destroy an execution environment and clean up resources.

  Should be idempotent - returns :ok even if environment doesn't exist.
  """
  @callback destroy(env :: ExecutionContext.t()) :: :ok | {:error, term()}

  @doc """
  Read a file from the file system.

  The execution-context reference may be used for remote file access in some implementations.
  """
  @callback read_file(env :: ExecutionContext.t(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  List contents of a directory.

  The execution-context reference may be used for remote directory access in some implementations.
  """
  @callback list_directory(env :: ExecutionContext.t(), path :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Write content to a file in the file system.

  Creates parent directories if they don't exist.
  The execution-context reference may be used for remote file access in some implementations.
  """
  @callback write_file(env :: ExecutionContext.t(), path :: String.t(), content :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Delete a file from the file system.

  Should be idempotent - returns :ok even if file doesn't exist.
  The execution-context reference may be used for remote file access in some implementations.
  """
  @callback delete_file(env :: ExecutionContext.t(), path :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Check if a file exists in the file system.

  The execution-context reference may be used for remote file access in some implementations.
  """
  @callback file_exists?(env :: ExecutionContext.t(), path :: String.t()) :: boolean()

  @doc """
  Find files matching a glob pattern relative to the execution context's working directory.

  Returns a list of matching file paths.
  """
  @callback glob(env :: ExecutionContext.t(), pattern :: String.t()) :: [String.t()]

  @doc """
  Ensure a directory exists, creating it and any parents if needed.

  Should be idempotent - returns :ok if directory already exists.
  """
  @callback ensure_dir(env :: ExecutionContext.t(), path :: String.t()) :: :ok | {:error, term()}

  @doc """
  Stat a regular file, returning its mtime and size.

  `mtime` is a truncated-to-second `DateTime` in UTC. Returns `{:error, :enoent}`
  for missing paths or non-regular files.
  """
  @callback stat(env :: ExecutionContext.t(), path :: String.t()) ::
              {:ok, %{mtime: DateTime.t(), size: non_neg_integer()}} | {:error, term()}

  @doc """
  Stream files under a set of whitelisted roots, recursing into subdirectories.

  Each root is resolved relative to the environment's `cwd`. Roots that don't
  exist are silently skipped. Emitted paths are relative to `cwd`.

  Roots may be either directories (walked recursively) or individual files
  (emitted directly). Implementations must prune — they must NOT walk outside
  the given roots.
  """
  @callback stream_files(env :: ExecutionContext.t(), roots :: [String.t()], opts :: keyword()) ::
              Enumerable.t()

  @doc """
  Run a command in the environment and return its output and exit status.

  Execution is a property of the environment for the same reason file access
  is: `mix test` has to run where the working copy lives.

  Implementations run in `env.cwd` unless the caller overrides `:cd`. `opts`
  otherwise follows `System.cmd/3`.

  Output is returned with ANSI escapes stripped and invalid UTF-8 scrubbed (it
  is bound for a database and JSON). It is **not** trimmed: for
  column-oriented output such as `git status --porcelain` the leading space is
  data.
  """
  @callback cmd(
              env :: ExecutionContext.t(),
              command :: String.t(),
              args :: [String.t()],
              opts :: keyword()
            ) :: {output :: String.t(), exit_code :: non_neg_integer()}

  @doc """
  Whether `path` exists in the filesystem the *shell* sees — the one `cmd/4`
  runs in.

  Usually the same answer as `file_exists?/2`, deliberately a separate
  question: in-memory test environments fake the domain filesystem while
  executing on the real one. A tool-availability check must follow `cmd/4`,
  or it concludes the tool is missing and silently skips it.

  Paths resolve against the environment's cwd, as everywhere else.
  """
  @callback exec_file_exists?(env :: ExecutionContext.t(), path :: String.t()) :: boolean()

  @doc """
  A recorded analyzer output file for `source`, replayed instead of running the
  analyzer. Only test environments implement it.
  """
  @callback recorded_output(env :: ExecutionContext.t(), source :: String.t()) :: String.t() | nil

  @optional_callbacks recorded_output: 2

  # Remove later, or reconsider:

  @callback environment_setup_command(env :: ExecutionContext.t(), attrs :: map()) :: String.t()
  @callback docs_environment_teardown_command(env :: ExecutionContext.t(), attrs :: map()) ::
              String.t()
  @callback test_environment_teardown_command(env :: ExecutionContext.t(), attrs :: map()) ::
              String.t()
  @callback code_environment_teardown_command(env :: ExecutionContext.t(), attrs :: map()) ::
              String.t()
end
