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

  @doc """
  Scope for a tool that is going to touch the disk.

  `validate_local_scope/2` is satisfied by a scope that names the project, which
  is all a tool reading or writing the database needs. A tool writing a *file*
  needs to know where the project is as well, and that is a different question:
  the scope arriving on the frame can carry a project id and no environment, in
  which case the branch that would have built one from the request's working
  directory is never reached.

  What that looked like: `create_component` reporting "this server has no
  working copy, so the stub spec was not written" and handing the agent its own
  stub to write. It reads as a limitation of the light harness. It was a scope
  resolved one step short.

  Resolving from `working_dir` matters more than having *an* environment,
  because it passes that directory to `Scope.for_local_project/2` as the root
  override. The fallback — the project's `local_path` column — holds a single
  path for a project that may have several checkouts, so every worktree except
  the recorded one would get an environment pointing into another tree. Writing
  a spec stub into the wrong checkout is worse than not writing it: story 886's
  drill left eight of them in the server's own repository while the agent's
  spec directory stayed empty, and nothing in the reply said so.
  """
  @spec validate_local_scope_with_working_copy(map(), map()) ::
          {:ok, struct()} | {:error, atom()}
  def validate_local_scope_with_working_copy(frame, params \\ %{}) do
    with {:ok, scope} <- validate_local_scope(frame, params) do
      ensure_working_copy(scope, frame.assigns[:working_dir])
    end
  end

  defp ensure_working_copy(%{environment: env} = scope, _working_dir) when not is_nil(env),
    do: {:ok, scope}

  defp ensure_working_copy(_scope, working_dir),
    do: resolve_scope_from_working_dir(working_dir)

  # A configured sprite knows its project without a directory, so a missing
  # working_dir is only fatal when the directory *is* the identity mechanism.
  defp resolve_scope_from_working_dir(nil) do
    case Application.get_env(:code_my_spec, :project_id) do
      nil -> {:error, :no_working_dir}
      _ -> do_resolve_scope(nil)
    end
  end

  defp resolve_scope_from_working_dir(working_dir), do: do_resolve_scope(working_dir)

  defp do_resolve_scope(working_dir) do
    require Logger
    alias CodeMySpec.Projects
    alias CodeMySpec.Users.Scope

    with {:ok, project} <- Projects.resolve_local_project(working_dir),
         {:ok, scope} <- Scope.for_local_project(project, working_dir) do
      {:ok, scope}
    else
      {:error, reason} ->
        Logger.warning(
          "[Validators] Failed to resolve scope from #{inspect(working_dir)}: #{inspect(reason)}"
        )

        {:error, :unauthorized}
    end
  end

  @doc """
  The working directory this request's project lives in, or nil if it does not
  live on this machine.

  For HTTP transport, from the X-Working-Dir header. For stdio, from
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
