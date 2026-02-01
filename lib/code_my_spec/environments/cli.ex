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
    session_id = Keyword.get(opts, :session_id, :rand.uniform(10000))
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
  Send a command to the tmux window for display. Does not capture output.

  Pattern matches on command type and dispatches appropriately.

  ## Returns

  - `:ok` - Command sent successfully
  - `{:error, reason}` - Failed to send command
  """
  @spec run_command(
          env :: Environment.t(),
          command :: CodeMySpec.Sessions.Command.t(),
          opts :: keyword()
        ) ::
          :ok | {:ok, map()} | {:error, term()}
  def run_command(_env, _command, _opts \\ [])

  # Handle empty commands - auto-complete with success
  def run_command(
        %Environment{},
        %CodeMySpec.Sessions.Command{command: cmd},
        _opts
      )
      when cmd == "" or is_nil(cmd) do
    {:ok, %{}}
  end

  def run_command(
        %Environment{} = env,
        %CodeMySpec.Sessions.Command{command: "read_file", metadata: %{"path" => path}},
        _opts
      ) do
    case read_file(env, path) do
      {:ok, content} -> {:ok, %{content: content}}
      error -> error
    end
  end

  def run_command(
        %Environment{} = env,
        %CodeMySpec.Sessions.Command{command: "list_directory", metadata: %{"path" => path}},
        _opts
      ) do
    list_directory(env, path)
  end

  def run_command(
        %Environment{ref: window_name},
        %CodeMySpec.Sessions.Command{command: "claude", metadata: metadata},
        _opts
      ) do
    with :ok <- ensure_window_or_pane_exists(window_name),
         {:ok, temp_path} <- Briefly.create(),
         prompt <- Map.get(metadata, "prompt", ""),
         args <- Map.get(metadata, "args", []),
         :ok <- File.write(temp_path, prompt) do
      claude_cmd = build_claude_command_with_pipe(temp_path, args)
      send_keys(window_name, claude_cmd)
      :ok
    end
  end

  def run_command(%Environment{}, %CodeMySpec.Sessions.Command{command: "pass"}, _opts) do
    {:ok, %{}}
  end

  # Fallback for legacy format where command field contains the actual shell command
  def run_command(
        %Environment{ref: window_name},
        %CodeMySpec.Sessions.Command{command: cmd},
        opts
      )
      when is_binary(cmd) do
    with :ok <- ensure_window_or_pane_exists(window_name) do
      env_vars = Keyword.get(opts, :env, %{})
      full_command = build_command_with_env(cmd, env_vars)

      send_keys(window_name, full_command)
    end
  end

  def environment_setup_command(_), do: ""

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
  def list_directory(_env, path) do
    File.ls(path)
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

  @doc false
  defp ensure_window_or_pane_exists(window_name) do
    # Check if pane with this title exists OR window exists
    unless adapter().pane_exists?(window_name) or adapter().window_exists?(window_name) do
      case adapter().create_window(window_name) do
        {:ok, _window_id} ->
          Logger.debug("Created tmux window: #{window_name}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to create tmux window #{window_name}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp build_claude_command_with_pipe(temp_path, args) when is_list(args) do
    # Build args string from list
    args_string =
      args
      |> Enum.map(&shell_escape/1)
      |> Enum.join(" ")

    # Build claude command with read @ syntax: claude [args] "read @tempfile"
    if args_string == "" do
      "claude \"read @#{temp_path}\""
    else
      "claude #{args_string} \"read @#{temp_path}\""
    end
  end

  defp build_command_with_env(command, env_vars) when map_size(env_vars) == 0 do
    command
  end

  defp build_command_with_env(command, env_vars) do
    exports =
      env_vars
      |> Enum.map(fn {key, value} -> "export #{key}=#{shell_escape(value)}" end)
      |> Enum.join("; ")

    "#{exports}; #{command}"
  end

  defp shell_escape(value) do
    # Simple shell escaping - wrap in single quotes and escape any single quotes
    "'#{String.replace(value, "'", "'\\''")}'"
  end

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

  defp send_keys(window_name, full_command) do
    case adapter().find_pane_by_title(window_name) do
      {:ok, pane_id} ->
        Logger.info("Found pane #{pane_id} with title #{window_name}, sending keys to pane")
        adapter().send_keys_to_pane(pane_id, full_command)

      {:error, :not_found} ->
        Logger.info("No pane with title #{window_name}, sending keys to window")
        adapter().send_keys(window_name, full_command)
    end
  end
end
