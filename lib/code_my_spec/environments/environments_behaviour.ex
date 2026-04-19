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

  # Remove later, or reconsider:

  @callback environment_setup_command(env :: Environment.t(), attrs :: map()) :: String.t()
  @callback docs_environment_teardown_command(env :: Environment.t(), attrs :: map()) ::
              String.t()
  @callback test_environment_teardown_command(env :: Environment.t(), attrs :: map()) ::
              String.t()
  @callback code_environment_teardown_command(env :: Environment.t(), attrs :: map()) ::
              String.t()
end
