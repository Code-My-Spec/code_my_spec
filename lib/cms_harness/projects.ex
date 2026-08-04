defmodule CmsHarness.Projects do
  @moduledoc """
  The projects this harness is serving.

  One harness, one endpoint, one lifecycle — and a supervision subtree per
  project underneath. Not a process per project: the hooks are POSTed to a
  fixed URL in the plugin's configuration, so a process per project means a
  port per project and a discovery step on the critical path of every agent
  turn, whose failure mode is a hook that silently posts nowhere.

  A sprite is simply N=1 here. Same code, same lifecycle, one child in the
  tree — which is the point, because a drill on a sprite is then a drill on the
  laptop path.
  """

  require Logger

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.ProjectIdentity

  @doc """
  Serve the project rooted at `dir`, starting its subtree if it is not already
  running.

  Idempotent, and safe to call from a hook request — which is how a laptop
  running several checkouts picks them up without being told about them in
  advance.
  """
  @spec ensure_started(String.t()) ::
          {:ok, ProjectIdentity.t()} | {:error, ProjectIdentity.t() | term()}
  def ensure_started(dir) when is_binary(dir) do
    with {:ok, project} <- ProjectIdentity.resolve(dir) do
      case DynamicSupervisor.start_child(
             CmsHarness.ProjectSupervisor,
             {CmsHarness.Project.Supervisor, project: project}
           ) do
        {:ok, _pid} ->
          Logger.info("[CmsHarness] serving project #{project.id} at #{project.root}")
          {:ok, project}

        {:error, {:already_started, _pid}} ->
          {:ok, project}

        {:error, reason} ->
          Logger.error("[CmsHarness] could not start project #{project.id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc "Every project id this harness currently has a subtree for."
  @spec list() :: [String.t()]
  def list do
    CmsHarness.Registry
    |> Registry.select([{{{:project, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Whether this harness can reach the server about a project.

  The single question the hook surface asks, so that "there is nothing to do"
  and "I could not ask" cannot be confused at the point where it matters.
  """
  @spec connected?(String.t()) :: boolean()
  def connected?(project_id), do: ChannelClient.connected?(project_id)

  @doc """
  Start the project named by the environment, if there is one.

  This is the sprite's path: one checkout, named by `CMS_PROJECT_DIR`, started
  at boot rather than waiting for the first hook. A laptop generally has none
  of this set and picks its projects up from hook requests instead.
  """
  @spec start_configured() :: :ok
  def start_configured do
    case System.get_env("CMS_PROJECT_DIR") ||
           Application.get_env(:code_my_spec, :harness_project_dir) do
      dir when is_binary(dir) and dir != "" ->
        case ensure_started(dir) do
          {:ok, _project} ->
            :ok

          {:error, reason} ->
            Logger.error("""
            [CmsHarness] CMS_PROJECT_DIR is #{dir} but the harness could not serve it: #{inspect(reason)}.

            Nothing is being watched and every hook for that directory will refuse.
            """)

            :ok
        end

      _ ->
        :ok
    end
  end
end
