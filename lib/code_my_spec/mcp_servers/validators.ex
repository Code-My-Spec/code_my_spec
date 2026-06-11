defmodule CodeMySpec.McpServers.Validators do
  @moduledoc """
  Validation functions for MCP servers.
  """

  @doc """
  Validates that the current scope has an active account set.
  Returns {:ok, frame} if valid, {:stop, :missing_active_account} if not.
  """
  def require_active_account(frame) do
    frame.assigns
    |> Map.get(:current_scope)
    |> case do
      nil -> nil
      scope -> scope.active_account_id || (scope.active_account && scope.active_account.id)
    end
    |> case do
      nil -> {:error, :missing_active_account}
      _account_id -> {:ok, frame}
    end
  end

  @doc """
  Validates that the current scope has an active project set.
  Returns {:ok, frame} if valid, {:stop, :missing_active_project} if not.
  """
  def require_active_project(frame) do
    frame.assigns
    |> Map.get(:current_scope)
    |> case do
      nil -> nil
      scope -> scope.active_project_id || (scope.active_project && scope.active_project.id)
    end
    |> case do
      nil -> {:error, :missing_active_project}
      _project_id -> {:ok, frame}
    end
  end

  def validate_scope(frame) do
    with {:ok, frame} <- require_active_account(frame),
         {:ok, frame} <- require_active_project(frame) do
      {:ok, frame.assigns.current_scope}
    end
  end

  @doc """
  Validates scope, falling back to resolving from a working_dir param.

  Use this for local MCP tools where scope may be injected via a PreToolUse
  hook that adds working_dir to the tool input.
  """
  def validate_local_scope(frame, _params \\ %{}) do
    case frame.assigns[:current_scope] do
      %{active_project_id: pid} = scope when not is_nil(pid) ->
        {:ok, scope}

      _ ->
        resolve_scope_from_working_dir(frame.assigns[:working_dir])
    end
  end

  defp resolve_scope_from_working_dir(nil), do: {:error, :no_working_dir}

  defp resolve_scope_from_working_dir(working_dir) do
    require Logger
    alias CodeMySpec.Projects
    alias CodeMySpec.Users.Scope

    with {:ok, project} <- Projects.get_project_by_local_path(working_dir),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, scope}
    else
      {:error, reason} ->
        Logger.warning("[Validators] Failed to resolve scope from #{working_dir}: #{inspect(reason)}")
        {:error, :unauthorized}
    end
  end

  @doc """
  Returns the MCP working directory from the frame context.

  For HTTP transport, this comes from the X-Working-Dir header.
  For stdio transport, this comes from Application.get_env (set by CLI).
  Falls back to File.cwd!() if not set.
  """
  def mcp_working_dir(frame) do
    # Try frame.assigns first (HTTP transport sets working_dir from header)
    # Fall back to Application.get_env (stdio transport sets it at startup)
    case frame.assigns do
      %{working_dir: dir} when is_binary(dir) -> dir
      _ -> Application.get_env(:code_my_spec, :mcp_working_dir, File.cwd!())
    end
  end

  @doc """
  Legacy function for backward compatibility.
  Prefer mcp_working_dir/1 with frame when available.
  """
  def mcp_working_dir do
    Application.get_env(:code_my_spec, :mcp_working_dir, File.cwd!())
  end

  @doc """
  Resolve the execution environment for a local MCP tool.

  Prefers the environment already attached to the current scope — in
  production that is the `:local` environment built from the project's
  `local_path`; in specs it is the in-memory environment seeded by
  `setup_active_project`. Falls back to a `:local` environment rooted at
  the resolved working dir for early bootstrap, where no project scope is
  resolved yet. Mirrors the `scope.environment || Environment.new(...)`
  pattern in `StartAgentTask` and `ArchitectureDesign`.
  """
  def mcp_environment(frame) do
    alias CodeMySpec.Environments.Environment

    case frame.assigns[:current_scope] do
      %{environment: %Environment{} = env} ->
        env

      _ ->
        Environment.new(:local, mcp_working_dir(frame))
    end
  end
end
