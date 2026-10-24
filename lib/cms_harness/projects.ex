defmodule CmsHarness.Projects do
  @moduledoc """
  The projects this harness is serving.

  One harness, one endpoint, one lifecycle — and a supervision subtree per
  **working copy** underneath, keyed on its root. Two checkouts of one project
  are two subtrees: they hold different files, so a manifest from one is not a
  statement about the other.

  Subtrees start on demand, when a hook names a harness id and
  `CmsHarness.WorkingCopies` asks the server where that copy is. Previously
  served roots bootstrap credentials after restart, but only the server's
  current device roster decides which roots are served. A sprite is N=1 of the
  same code.

  See knowledge/harness/channel, "Projects and working copies".
  """

  require Logger

  alias CmsHarness.Channel
  alias CmsHarness.Copy.Supervisor, as: Copy
  alias CmsHarness.ProjectIdentity
  alias CmsHarness.ServedRoots
  alias CmsHarness.WorkingCopies.Create

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
    with :ok <- not_preparing(dir),
         {:ok, project} <- ProjectIdentity.resolve(dir) do
      # Under the copy's own supervisor, beside its agents and its app.
      case Copy.serve(project.root, project) do
        {:started, _pid} ->
          ServedRoots.remember(project.root)
          Logger.info("[CmsHarness] serving project #{project.id} at #{project.root}")
          {:ok, project}

        # Keyed on the root, so this means *this working copy* is served.
        # See knowledge/harness/channel, "Projects and working copies".
        {:already_started, _pid} ->
          ServedRoots.remember(project.root)
          {:ok, project}

        {:error, reason} ->
          Logger.error("[CmsHarness] could not start project #{project.id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Start the working copy named by the environment, if there is one.

  Reads `CMS_PROJECT_DIR`. The sprite's path: its agent waits for an accepted
  manifest before it starts, so a harness that waited for a hook would wait
  forever.

  Errors are logged and swallowed: a hook naming a different copy can still be
  answered, and a harness that refuses to start answers nothing.
  """
  @spec start_configured() :: :ok
  def start_configured do
    case System.get_env("CMS_PROJECT_DIR") do
      dir when is_binary(dir) and dir != "" ->
        serve_configured(dir)

      _ ->
        :ok
    end
  end

  defp serve_configured(dir) do
    case ensure_started(dir) do
      {:ok, _project} ->
        :ok

      {:error, reason} ->
        Logger.error("""
        [CmsHarness] CMS_PROJECT_DIR is #{dir} but the harness could not serve it: #{inspect(reason)}.

        Nothing is being watched there and every hook for that directory will
        refuse. On a sprite this is fatal in practice: the agent waits for a
        manifest that will never be sent.
        """)

        :ok
    end
  end

  @doc "Every working-copy root this harness currently has a subtree for."
  @spec list() :: [String.t()]
  # `[]` before the registry is up: `Credentials.any/0` calls this during boot,
  # and nothing is served before the registry exists.
  def list do
    case Process.whereis(CmsHarness.Registry) do
      nil -> []
      _ -> Registry.select(CmsHarness.Registry, [{{{:project, :"$1"}, :_, :_}, [], [:"$1"]}])
    end
  end

  @doc """
  Whether this harness can reach the server about a project.

  The single question the hook surface asks, so that "there is nothing to do"
  and "I could not ask" cannot be confused at the point where it matters.
  """
  @spec connected?(String.t()) :: boolean()
  def connected?(root), do: Channel.connected?(root)

  @doc """
  Stop serving a working copy, releasing its channel and its watchers.

  The counterpart to `ensure_started/1`, called when a copy is offboarded on
  the server. `{:error, :not_serving}` for a root not served; callers treat it
  as satisfied, so an offboard that arrives twice does not fail.
  """
  @spec stop_serving(String.t()) :: :ok | {:error, :not_serving}
  def stop_serving(root) when is_binary(root) do
    ServedRoots.forget(root)

    # App dependencies are disposed explicitly by offboarding before this call.
    # This stops the copy channel and agents; app supervision is independent.
    case Copy.stop(root) do
      :ok ->
        Logger.info("[CmsHarness] no longer serving #{root} — offboarded on the server")
        :ok

      {:error, :not_found} ->
        {:error, :not_serving}
    end
  end

  @doc """
  Drop one working copy's channel and take it up again.

  The reconnect a harness restart performs, for one root instead of all of
  them. A fresh join runs the server's `agents_to_restore` handshake, so this
  copy's agents are named and relaunched; other copies are untouched.

  This copy's in-flight analyzers die with its channel chain; its next stop
  re-enqueues them. Sequential rather than a supervised restart so
  `ensure_started/1` re-reads the config and the join is fresh.
  """
  @spec rejoin(String.t()) :: {:ok, ProjectIdentity.t()} | {:error, term()}
  def rejoin(root) when is_binary(root) do
    Logger.info("[CmsHarness] rejoining #{root} — this copy's channel only")

    # The channel chain only: the copy's agents and app are siblings of it
    # and keep running, and the fresh join reports them.
    _ = Copy.unserve(root)
    ensure_started(root)
  end

  # A copy still being prepared — the promotion gate running its project's
  # setup — is served once that finishes, not before.
  defp not_preparing(dir) do
    if Create.preparing?(dir), do: {:error, :preparing}, else: :ok
  end
end
