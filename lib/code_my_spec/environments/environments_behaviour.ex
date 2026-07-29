defmodule CodeMySpec.Environments.EnvironmentsBehaviour do
  @moduledoc """
  Behaviour for environment implementations.

  Environments define HOW commands execute (not WHAT commands to generate).
  Each implementation handles execution in its specific context (CLI with tmux, Server, VSCode).
  """

  alias CodeMySpec.Environments.Environment

  @doc """
  Create an execution environment.

  Returns an Environment struct containing implementation-specific references.
  """
  @callback create(opts :: keyword()) :: {:ok, Environment.t()} | {:error, term()}

  @doc """
  Destroy an execution environment and clean up resources.

  Should be idempotent - returns :ok even if environment doesn't exist.
  """
  @callback destroy(env :: Environment.t()) :: :ok | {:error, term()}

  @doc """
  Read a file from the file system.

  The environment reference may be used for remote file access in some implementations.
  """
  @callback read_file(env :: Environment.t(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  List contents of a directory.

  The environment reference may be used for remote directory access in some implementations.
  """
  @callback list_directory(env :: Environment.t(), path :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Write content to a file in the file system.

  Creates parent directories if they don't exist.
  The environment reference may be used for remote file access in some implementations.
  """
  @callback write_file(env :: Environment.t(), path :: String.t(), content :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Delete a file from the file system.

  Should be idempotent - returns :ok even if file doesn't exist.
  The environment reference may be used for remote file access in some implementations.
  """
  @callback delete_file(env :: Environment.t(), path :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Check if a file exists in the file system.

  The environment reference may be used for remote file access in some implementations.
  """
  @callback file_exists?(env :: Environment.t(), path :: String.t()) :: boolean()

  @doc """
  Find files matching a glob pattern relative to the environment's working directory.

  Returns a list of matching file paths.
  """
  @callback glob(env :: Environment.t(), pattern :: String.t()) :: [String.t()]

  @doc """
  Ensure a directory exists, creating it and any parents if needed.

  Should be idempotent - returns :ok if directory already exists.
  """
  @callback ensure_dir(env :: Environment.t(), path :: String.t()) :: :ok | {:error, term()}

  @doc """
  Stat a regular file, returning its mtime and size.

  `mtime` is a truncated-to-second `DateTime` in UTC. Returns `{:error, :enoent}`
  for missing paths or non-regular files.
  """
  @callback stat(env :: Environment.t(), path :: String.t()) ::
              {:ok, %{mtime: DateTime.t(), size: non_neg_integer()}} | {:error, term()}

  @doc """
  Stream files under a set of whitelisted roots, recursing into subdirectories.

  Each root is resolved relative to the environment's `cwd`. Roots that don't
  exist are silently skipped. Emitted paths are relative to `cwd`.

  Roots may be either directories (walked recursively) or individual files
  (emitted directly). Implementations must prune — they must NOT walk outside
  the given roots.
  """
  @callback stream_files(env :: Environment.t(), roots :: [String.t()], opts :: keyword()) ::
              Enumerable.t()

  @doc """
  Run a command in the environment and return its output and exit status.

  Execution is a property of the environment for the same reason file access
  is: `mix test` has to run where the working copy lives. Every shell-out in
  the system goes through here, so moving the code somewhere other than the
  machine holding the checkout is a matter of adding an implementation rather
  than of finding and rewriting call sites.

  Implementations run in `env.cwd` unless the caller overrides `:cd`. `opts`
  otherwise follows `System.cmd/3`.

  Output is returned cleaned — ANSI stripped, valid UTF-8, trimmed — because
  it is bound for a database and a JSON response, and neither tolerates raw
  terminal bytes.
  """
  @callback cmd(
              env :: Environment.t(),
              command :: String.t(),
              args :: [String.t()],
              opts :: keyword()
            ) :: {output :: String.t(), exit_code :: non_neg_integer()}

  @doc """
  Whether `path` exists in the filesystem the *shell* sees — the one `cmd/4`
  runs in.

  Usually the same answer as `file_exists?/2`, and deliberately a separate
  question. `file_exists?/2` reports on the domain's filesystem; this reports
  on the execution filesystem. The in-memory test environments are where they
  come apart: they fake the domain filesystem while delegating execution to
  the real one, so `deps/credo` is present to a spawned `mix` and absent to
  `read_file/2`. A tool-availability check has to follow `cmd/4`, not
  `read_file/2`, or it concludes the tool is missing and silently skips it.

  Paths resolve against the environment's cwd, as everywhere else.
  """
  @callback exec_file_exists?(env :: Environment.t(), path :: String.t()) :: boolean()

  # Remove later, or reconsider:

  @callback environment_setup_command(env :: Environment.t(), attrs :: map()) :: String.t()
  @callback docs_environment_teardown_command(env :: Environment.t(), attrs :: map()) ::
              String.t()
  @callback test_environment_teardown_command(env :: Environment.t(), attrs :: map()) ::
              String.t()
  @callback code_environment_teardown_command(env :: Environment.t(), attrs :: map()) ::
              String.t()
end
