defmodule CodeMySpec.Environments.Cli do
  @moduledoc """
  Executes commands in tmux windows for CLI display.

  Commands run for demonstration purposes; output capture not supported.
  Delegates to TmuxAdapter for testability.
  """

  @behaviour CodeMySpec.Environments.EnvironmentsBehaviour
  alias CodeMySpec.Environments.Cli.TmuxAdapter
  alias CodeMySpec.Environments.Environment
  require Logger

  # Allow adapter injection for testing
  defp adapter do
    Application.get_env(:code_my_spec, :tmux_adapter, TmuxAdapter)
  end

  @doc """
  Create an environment for command execution (lazy window creation).

  The tmux window is not created immediately. Instead, it's created on-demand
  when the first command runs. This allows for more efficient resource usage.

  ## Options

  - `:session_id` - Used for window naming (e.g., "session-123")
  - `:working_dir` - Current working directory for the environment
  - `:metadata` - Optional metadata to include in Environment struct

  ## Returns

  - `{:ok, %Environment{}}` - Environment created successfully
  - `{:error, reason}` - Failed to validate environment (e.g., not inside tmux)
  """
  @spec create(opts :: keyword()) :: {:ok, Environment.t()} | {:error, term()}
  def create(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, :rand.uniform(10_000))
    window_name = "session-#{session_id}"
    working_dir = Keyword.get(opts, :working_dir)
    metadata = Keyword.get(opts, :metadata, %{})

    {:ok,
     %Environment{
       type: :cli,
       ref: window_name,
       cwd: working_dir,
       metadata: metadata
     }}
  end

  @doc """
  Destroy a tmux window and clean up resources.

  This function is idempotent - returns `:ok` even if the window doesn't exist.
  Since window creation is lazy, this might be called on a window that was never created.
  """
  @spec destroy(env :: Environment.t()) :: :ok | {:error, term()}
  def destroy(%Environment{ref: window_name}) do
    case adapter().kill_window(window_name) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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
