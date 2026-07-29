defmodule CodeMySpec.Environments.Cli do
  @moduledoc """
  Server-side filesystem environment for the CLI binary path.

  Reads, writes, and stats files on the local filesystem with paths
  resolved against an optional working directory carried on the
  environment struct.

  `create/1` and `destroy/1` are kept as no-op lifecycle hooks for
  symmetry with other environment implementations — the CLI environment
  has no external resources (windows, panes, etc.) to allocate or
  release.
  """

  @behaviour CodeMySpec.Environments.EnvironmentsBehaviour
  alias CodeMySpec.Environments.Environment
  require Logger

  @doc """
  Create an environment for filesystem operations.

  ## Options

  - `:session_id` - Used for the environment `ref` (e.g., "session-123")
  - `:working_dir` - Current working directory for the environment
  - `:metadata` - Optional metadata to include in Environment struct

  ## Returns

  - `{:ok, %Environment{}}` - Environment created successfully
  """
  @spec create(opts :: keyword()) :: {:ok, Environment.t()}
  def create(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, :rand.uniform(10_000))
    ref = "session-#{session_id}"
    working_dir = Keyword.get(opts, :working_dir)
    metadata = Keyword.get(opts, :metadata, %{})

    {:ok,
     %Environment{
       type: :cli,
       ref: ref,
       cwd: working_dir,
       metadata: metadata
     }}
  end

  @doc """
  No-op destroy. The CLI environment owns no external resources so
  there's nothing to release. Returns `:ok` for behaviour symmetry.
  """
  @spec destroy(env :: Environment.t()) :: :ok
  def destroy(%Environment{}), do: :ok

  @doc """
  Run a command. Delegates to `Local` — both environments are the local
  filesystem on the local host, so they share one shell. They differ in how
  paths are resolved, not in where commands run.
  """
  @spec cmd(Environment.t(), String.t(), [String.t()], keyword()) ::
          {String.t(), non_neg_integer()}
  # Execution is delegated to Local, so the execution filesystem is Local's
  # — same filesystem, same host.
  defdelegate exec_file_exists?(env, path), to: CodeMySpec.Environments.Local

  defdelegate cmd(env, command, args, opts), to: CodeMySpec.Environments.Local

  @doc """
  Read a file from the server-side file system.

  Resolves paths relative to the environment's working directory if set.
  """
  @spec read_file(env :: Environment.t(), path :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def read_file(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.read(resolved_path)
  end

  @doc """
  List contents of a directory from the server-side file system.

  The environment reference is not used since file operations are server-side.
  """
  @spec list_directory(env :: Environment.t(), path :: String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_directory(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.ls(resolved_path)
  end

  @doc """
  Write content to a file on the server-side file system.

  Creates parent directories if they don't exist.
  Resolves paths relative to the environment's working directory if set.
  """
  @spec write_file(env :: Environment.t(), path :: String.t(), content :: String.t()) ::
          :ok | {:error, term()}
  def write_file(env, path, content) do
    resolved_path = resolve_path(path, env.cwd)
    Logger.info("write file called")

    with :ok <- ensure_parent_directory(resolved_path) do
      Logger.info("parent directory ensured")
      File.write(resolved_path, content)
    end
  end

  @doc """
  Delete a file from the server-side file system.

  Idempotent - returns :ok even if file doesn't exist.
  Resolves paths relative to the environment's working directory if set.
  """
  @spec delete_file(env :: Environment.t(), path :: String.t()) ::
          :ok | {:error, term()}
  def delete_file(env, path) do
    resolved_path = resolve_path(path, env.cwd)

    case File.rm(resolved_path) do
      :ok -> :ok
      # File doesn't exist, that's fine
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a file exists on the server-side file system.

  Resolves paths relative to the environment's working directory if set.
  """
  @spec file_exists?(env :: Environment.t(), path :: String.t()) :: boolean()
  def file_exists?(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.exists?(resolved_path)
  end

  @doc """
  Stat a file on the server-side file system.
  """
  @spec stat(env :: Environment.t(), path :: String.t()) ::
          {:ok, %{mtime: DateTime.t(), size: non_neg_integer()}} | {:error, term()}
  def stat(env, path) do
    resolved_path = resolve_path(path, env.cwd)

    case File.stat(resolved_path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime_posix}} ->
        mtime = mtime_posix |> DateTime.from_unix!() |> DateTime.truncate(:second)
        {:ok, %{mtime: mtime, size: size}}

      {:ok, _} ->
        {:error, :not_regular}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Find files matching a glob pattern relative to the environment's working directory.
  """
  @spec glob(env :: Environment.t(), pattern :: String.t()) :: [String.t()]
  def glob(env, pattern) do
    resolved_pattern = resolve_path(pattern, env.cwd)
    Path.wildcard(resolved_pattern)
  end

  def ensure_dir(env, path) do
    resolved_path = resolve_path(path, env.cwd)
    File.mkdir_p(resolved_path)
  end

  @doc """
  Stream files under a whitelisted set of roots.

  Delegates to DirWalker, pruning to the given subtrees only.
  """
  @spec stream_files(env :: Environment.t(), roots :: [String.t()], opts :: keyword()) ::
          Enumerable.t()
  def stream_files(env, roots, _opts \\ []) do
    base = env.cwd || File.cwd!()

    existing =
      roots
      |> Enum.map(&Path.join(base, &1))
      |> Enum.filter(&File.exists?/1)

    case existing do
      [] ->
        Stream.map([], & &1)

      paths ->
        paths
        |> DirWalker.stream()
        |> Stream.map(&Path.relative_to(&1, base))
    end
  end

  def environment_setup_command(_, _) do
    "pass"
  end

  def docs_environment_teardown_command(_, _) do
    "pass"
  end

  def test_environment_teardown_command(_, _) do
    "pass"
  end

  def code_environment_teardown_command(_, _) do
    "pass"
  end

  # Private functions

  defp ensure_parent_directory(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  # Resolve path relative to working_dir if it's a relative path
  defp resolve_path(path, nil), do: path

  defp resolve_path(path, working_dir) do
    if Path.type(path) == :relative do
      Path.join(working_dir, path) |> Path.absname()
    else
      path
    end
  end
end
