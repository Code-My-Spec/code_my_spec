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
      scope -> Map.get(scope, :active_account)
    end
    |> case do
      nil -> {:error, :missing_active_account}
      _account -> {:ok, frame}
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
      scope -> Map.get(scope, :active_project)
    end
    |> case do
      nil -> {:error, :missing_active_project}
      _project -> {:ok, frame}
    end
  end

  def validate_scope(frame) do
    with {:ok, frame} <- require_active_account(frame),
         {:ok, frame} <- require_active_project(frame) do
      {:ok, frame.assigns.current_scope}
    end
  end

  @doc """
  Validates that the current scope has an active project set (no account required).
  Use this for local/CLI operations that don't need account context.
  Returns {:ok, scope} if valid, {:error, reason} if not.
  """
  def validate_project_scope(frame) do
    with {:ok, frame} <- require_active_project(frame) do
      {:ok, frame.assigns.current_scope}
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
end
