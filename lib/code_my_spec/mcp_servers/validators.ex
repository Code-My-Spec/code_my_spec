defmodule CodeMySpec.McpServers.Validators do
  @moduledoc """
  Validation functions for MCP servers.
  """

  alias CodeMySpec.Environments.Environment

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
  The scope for a local MCP tool.

  Over HTTP this is decided before the tool runs: `Plugs.HarnessScope` resolves
  the harness id the request names, loads its project, and assigns the scope, so
  the first clause matches and this is a read.

  ## Why there is no directory fallback

  There was: a working copy could be identified by matching the directory a
  request announced against `projects.local_path`. It is gone with the rest of
  working-directory resolution — the directory a request announces is a
  filesystem path supplied from outside, and a wrong one did not fail, it
  succeeded against the wrong disk.

  What is left is the stdio transport, which has no connection and therefore no
  assigns. There the project is named in configuration (`:project_id`, set at
  startup), which is a fact about the installation rather than about the
  request. `nil` and a configured project are the only two answers.
  """
  def validate_local_scope(frame, _params \\ %{}) do
    case frame.assigns[:current_scope] do
      %{active_project_id: pid} = scope when not is_nil(pid) ->
        {:ok, scope}

      _ ->
        configured_scope(Application.get_env(:code_my_spec, :project_id))
    end
  end

  @doc """
  The project a devops tool acts on — always the one this call is already
  scoped to, never one a caller names.

  `validate_local_scope/2` already resolves the right project before a tool
  ever runs: the harness's own `X-Project-ID` header for HTTP, or the
  configured project for stdio. A devops tool that *also* accepted an
  explicit `project_id` parameter was trusting that parameter over the
  connection's own identity — `find_project/2`-style lookups only checked
  "is this project somewhere in the caller's account", not "is it the one
  this call is actually connected to". A caller (or a wrong parameter from
  an agent) could act on a *different* project in the same account than the
  one its own harness names, silently. This is the fix: the only project a
  devops tool can ever act on is the one already on the scope.
  """
  @spec devops_project(CodeMySpec.Users.Scope.t()) :: {:ok, struct()} | {:error, String.t()}
  def devops_project(%{active_project: %{} = project}), do: {:ok, project}

  def devops_project(_scope),
    do:
      {:error,
       "no project is connected to this call — this tool acts on whichever project the " <>
         "connection itself identifies, not one named in a parameter"}

  defp configured_scope(nil), do: {:error, :no_working_dir}

  defp configured_scope(_project_id) do
    require Logger
    alias CodeMySpec.Projects
    alias CodeMySpec.Users.Scope

    with {:ok, project} <- Projects.resolve_local_project(nil),
         {:ok, scope} <- Scope.for_local_project(project, nil) do
      {:ok, scope}
    else
      {:error, reason} ->
        Logger.warning(
          "[Validators] Failed to resolve the configured project: #{inspect(reason)}"
        )

        {:error, :unauthorized}
    end
  end

  @doc """
  The working directory this request's project lives in, or nil if it does not
  live on this machine.

  For HTTP transport, from the scope `Plugs.HarnessScope` resolved — the
  harness's own recorded root, not anything the request said. For stdio, from
  `Application.get_env` — the CLI sets it at startup from `CMS_MCP_WORKING_DIR`,
  and there cwd genuinely is the project.

  ## Why there is no `File.cwd!()` fallback

  There was one. It was written for early bootstrap on a developer's machine,
  where the current directory is the project and defaulting to it is right.

  On a server it is not right, and it does not fail — it succeeds against the
  wrong disk. The light-harness mount carries a project id and no working
  directory, because the project's working copy is on the harness; the fallback
  turned that into a `:local` environment rooted at the server's own checkout.
  `install_agents_md` then reported `Installed: .code_my_spec/AGENTS.md`,
  truthfully, having written it into this repository. An agent in a container
  called it, saw success, found its own file unchanged, and could not tell the
  difference between "already correct" and "written somewhere else entirely".

  Nil means the caller must not touch a filesystem. Every caller here can say
  so; none of them could have detected the wrong one.
  """
  @spec mcp_working_dir(map()) :: String.t() | nil
  def mcp_working_dir(frame) do
    case frame.assigns do
      %{working_dir: dir} when is_binary(dir) -> dir
      _ -> Application.get_env(:code_my_spec, :mcp_working_dir)
    end
  end

  @doc """
  Legacy function for backward compatibility.
  Prefer mcp_working_dir/1 with frame when available.
  """
  @spec mcp_working_dir() :: String.t() | nil
  def mcp_working_dir do
    Application.get_env(:code_my_spec, :mcp_working_dir)
  end

  @doc """
  Resolve the execution environment for a local MCP tool, or nil when this
  machine holds no working copy for the request.

  Prefers the environment already attached to the current scope — in
  production that is the `:local` environment built from the project's
  `local_path`; in specs it is the in-memory environment seeded by
  `setup_active_project`. Falls back to a `:local` environment rooted at
  the resolved working dir for early bootstrap, where no project scope is
  resolved yet.

  Returns nil when there is no working directory to root one at. See
  `mcp_working_dir/1` for why guessing is worse than refusing.
  """
  @spec mcp_environment(map()) :: Environment.t() | nil
  def mcp_environment(frame) do
    case frame.assigns[:current_scope] do
      %{environment: %Environment{} = env} ->
        env

      _ ->
        case mcp_working_dir(frame) do
          nil -> nil
          dir -> Environment.new(:local, dir)
        end
    end
  end

  @doc """
  The reply a filesystem-bound tool gives when this machine has no working copy.

  Shared so every one of them says the same thing, and says what to do instead
  rather than only what failed.
  """
  @spec no_working_copy_message(String.t()) :: String.t()
  def no_working_copy_message(tool) do
    """
    `#{tool}` needs the project's files, and this server does not have them.

    The working copy lives on the harness — that is the design, not a \
    misconfiguration. Write the file there yourself; the harness syncs it back \
    and the requirement will clear on the next evaluation.

    (If you expected this server to hold the project, it was started without \
    CMS_MCP_WORKING_DIR.)\
    """
  end
end
