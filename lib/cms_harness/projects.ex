defmodule CmsHarness.Projects do
  @moduledoc """
  The projects this harness is serving.

  One harness, one endpoint, one lifecycle — and a supervision subtree per
  **working copy** underneath, keyed on its root. Two checkouts of one project
  are two subtrees: they hold different files, so a manifest from one is not a
  statement about the other.

  Not an OS process per working copy: the hooks are POSTed to a fixed URL in
  the plugin's configuration, so a process apiece means a port apiece and a
  discovery step on the critical path of every agent turn, whose failure mode
  is a hook that silently posts nowhere.

  Nothing is configured here. Subtrees start on demand, when a hook names a
  harness id and `CmsHarness.WorkingCopies` asks the server where that copy is.
  There is no list of directories to keep — a list would put the operator back
  in the business of telling the harness about paths, and it would be a second
  record of something the server already holds.

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

  Idempotent, and safe to call from a hook request — which is how every
  checkout is picked up, laptop or sprite, without any of them being configured
  in advance. `dir` comes from the server's record of the harness, never from
  the request.
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

        # Now that the subtree is keyed on the root, this means *this working
        # copy* is already served, and returning the caller's project is
        # truthful. Keyed on `project.id` it did not: a second checkout of one
        # project resolved the same id, landed here, and got back its own root
        # while the running subtree watched the first one — hooks answered, the
        # health endpoint said served, and every file event belonged to a tree
        # nobody asked about. Issue 8b83ba20.
        {:error, {:already_started, _pid}} ->
          {:ok, project}

        {:error, reason} ->
          Logger.error("[CmsHarness] could not start project #{project.id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc "Every working-copy root this harness currently has a subtree for."
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
  def connected?(root), do: ChannelClient.connected?(root)
end
