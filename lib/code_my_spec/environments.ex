defmodule CodeMySpec.Environments do
  @moduledoc """
  Provides execution primitives for running commands and file system operations
  across different execution contexts (server, CLI with tmux, VS Code client).

  This module delegates to specific environment implementations while maintaining
  a consistent interface through the opaque Environment struct.
  """

  alias CodeMySpec.Environments.Environment

  @doc """
  Create a new execution context and return an opaque Environment struct.

  ## Parameters

  - `type` - Environment type (`:cli`, `:server`, `:vscode`)
  - `opts` - Options passed to the implementation's `create/1` function

  ## Returns

  - `{:ok, %Environment{}}` - Environment created successfully
  - `{:error, reason}` - Failed to create environment

  ## Examples

      # Create CLI environment with tmux
      {:ok, env} = Environments.create(:cli, session_id: 123)

      # Create server environment
      {:ok, env} = Environments.create(:server)
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

  defp impl(:server) do
    # Server implementation not yet created
    {:error, "Server environment not implemented"}
  end

  defp impl(type) do
    {:error, "Unknown environment type: #{inspect(type)}"}
  end

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

  def cmd(environment, command, args, opts \\ []),
    do: impl(environment).cmd(command, args, opts)
end
