defmodule CodeMySpec.Staffing do
  @moduledoc """
  A working copy and the agents on it, changed together.

  `WorkingCopies` records copies; `Agents` runs the agents that work in them.
  Three acts touch both — making a copy and staffing it, moving the main
  designation and the main agent with it, and offboarding a copy and ending its
  agents — and they live here so that neither context has to call the other.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      # Offboarding removes the copy's derived rows before its own; the
      # contexts that own them sit below WorkingCopies' callers, not under it.
      CodeMySpec.Components,
      CodeMySpec.Files,
      CodeMySpec.Problems,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies,
      # Offboarding a copy that was sharing a device's tunnel has to drop its
      # ingress rule and DNS record before the row goes — otherwise Cloudflare
      # keeps answering for a hostname nothing here remembers any more.
      CodeMySpec.Workspaces
    ]

  require Logger

  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Agents.Transport.Harness
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpec.Workspaces.PreviewTunnel

  @gate_copy_needed [:code_my_spec, :promotion_queue, :gate_copy_needed]

  @doc """
  Attach the handler that makes a project's promotion gate copy when its queue
  asks for one. Called once, after the application tree starts.

  The queue sits below this module, so it asks by event rather than by call. A
  gate copy is a checkout with no agents: the queue builds and gates batches in
  it, and nobody works there.
  """
  def attach do
    :telemetry.attach(
      {__MODULE__, :gate_copy},
      @gate_copy_needed,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(
        @gate_copy_needed,
        _measurements,
        %{scope: scope, label: label} = metadata,
        _config
      ) do
    case mint(scope, label: label, roles: [], host_copy_id: metadata[:source_copy_id]) do
      {:ok, copy, _staffed} ->
        Logger.info("[Staffing] made the promotion gate copy #{copy.id} at #{copy.root}")

      {:error, reason} ->
        Logger.error("[Staffing] could not make the promotion gate copy: #{inspect(reason)}")
    end
  catch
    kind, reason ->
      Logger.error(
        "[Staffing] making the promotion gate copy failed: #{Exception.format_banner(kind, reason)}"
      )
  end

  @doc """
  Make a working copy for this project and staff it.

  One act with two halves in two places: the harness makes the checkout on its
  own disk and writes the identity into it, and this records the copy and starts
  the agents that will work in it. The caller makes one call.

  Callers: an agent asking for somewhere to work, `EpicDispatch` placing an
  epic, and the promotion gate copy (`roles: []`).

  Answers `{:ok, copy, staffed}` where `staffed` is
  `Agents.ensure_copy_agents/3`'s report (plus `:setup`). A copy that could not
  be staffed is still a copy: the failure is reported, not rolled back.
  """
  @spec mint(Scope.t(), keyword()) ::
          {:ok, WorkingCopy.t(), map()} | {:error, term()}
  def mint(%Scope{active_project_id: project_id} = scope, opts \\ [])
      when is_binary(project_id) do
    # Candidate hosts: copies that report a root, the main checkout first. A new
    # copy is made under its host's root (`.claude/worktrees/<name>`), so a
    # worktree host nests; the rest stay as fallbacks for when main is offline.
    copies =
      scope
      |> WorkingCopies.list_harnesses()
      |> Enum.filter(&(is_binary(&1.root) and &1.root != ""))

    candidates =
      copies
      |> Enum.sort_by(& &1.main, :desc)
      |> Enum.map(& &1.id)
      |> then(fn ids ->
        if opts[:host_copy_id], do: Enum.filter(ids, &(&1 == opts[:host_copy_id])), else: ids
      end)

    request = %{
      "project_id" => project_id,
      # The identity travels to the harness, so the file on disk and the row
      # hold one value, not two derivations of it.
      "working_copy_id" => Ecto.UUID.generate(),
      "label" => opts[:label],
      "root" => opts[:root],
      # A copy that cannot authenticate never joins, so the key goes with it.
      "deploy_key" => opts[:deploy_key] || deploy_key(scope),
      # Every copy is prepared by the project's own recipe (envs decrypted,
      # deps fetched, test database created and migrated) before it is
      # served -- John, 2026-10-19: "we should for sure do all the setup on
      # every copy at creation." Not a caller's choice to make.
      "prepare" => true
    }

    case Transport.impl().create_working_copy(candidates, request, 60_000) do
      {:ok, made} -> register(scope, candidates, made, opts)
      {:error, _reason} = error -> error
    end
  end

  # Issue 37f35126: the harness's own transport-level ack (whether this
  # call's push arrived) is not evidence this registration succeeded --
  # that runs here, in this process, after the ack-bearing push has already
  # been handled on the other side. The harness has to be told the real
  # outcome explicitly, or a registration failure after a genuine checkout
  # leaves it behind with no agents, no row, and nothing that will ever
  # roll it back -- its own ack-timeout safety net only catches a create
  # whose result never reached the server at all, which this is not.
  defp register(scope, candidates, %{root: root, working_copy_id: id} = made, opts) do
    result =
      with {:ok, copy} <-
             WorkingCopies.issue(scope, id,
               root: root,
               label: opts[:label],
               device: host_device(scope, opts[:host_copy_id]),
               # Already written into the checkout's config; a row under
               # another id is a copy nothing can recognise.
               working_copy_id: id
             ),
           {:ok, copy} <- WorkingCopies.report_root(copy, root) do
        # `:setup` says whether the project's own `init-worktree` recipe set
        # the copy up or the harness fell back to a bare worktree (no deps,
        # no `_build`, no untracked config) — the caller must be told.
        staffed =
          scope
          |> Agents.ensure_copy_agents(copy, opts[:roles] || Agents.copy_roles())
          |> Map.put(:setup, Map.get(made, :setup))

        {:ok, copy, staffed}
      end

    Harness.report_working_copy_registration(candidates, id, registration_outcome(result))

    result
  end

  defp registration_outcome({:ok, _copy, _staffed}), do: :ok
  defp registration_outcome({:error, reason}), do: {:error, reason}

  @doc """
  Designate a working copy as the project's main one, and move the main agent
  to it.

  See `WorkingCopies.designate_main/2` for what designation means and what it
  refuses.
  """
  @spec designate_main(Scope.t(), Ecto.UUID.t()) ::
          {:ok, WorkingCopy.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def designate_main(%Scope{} = scope, working_copy_id) do
    with {:ok, copy} <- WorkingCopies.designate_main(scope, working_copy_id) do
      # The agent goes where the designation goes.
      _ = Agents.move_main_agent(scope, copy)
      {:ok, copy}
    end
  end

  @doc """
  End the agents on a working copy, then offboard it.

  Then remove the copy and everything derived from it: files and problems
  unconditionally; components only where they have no files **and** no story
  link; then the row. Answers those counts plus `agents_stopped` and
  `agents_left_running`.

  Refuses rather than offboarding, without removing anything, when a shared
  copy's preview could not be released — see the reasoning inline. The copy
  stays exactly as it was; offboarding it is safe to retry once whatever
  Cloudflare error caused it clears.

  An act a person takes, never a sweep on elapsed time: the harness reports a
  missing path as a warning and a person decides. The row goes too (a copy
  reappearing at the path onboards with a new id). The checkout on disk is
  never touched.

  See knowledge/agents/coordination, "Staffing".
  """
  @spec offboard(Scope.t(), WorkingCopy.t()) ::
          {:ok, map()} | {:error, :not_yours} | {:error, {:preview_not_released, term()}}
  def offboard(
        %Scope{active_project_id: project_id} = scope,
        %WorkingCopy{
          project_id: project_id,
          id: id
        } = copy
      )
      when is_binary(project_id) do
    # The agents first, outside the transaction (stopping is a request to a
    # machine). Best-effort: the usual case is a copy whose machine is gone, and
    # that must stay offboardable.
    agents = stop_agents_on(scope, id)

    # Not best-effort: releasing a shared preview talks to Cloudflare, not the
    # machine. If it fails the ingress rule or DNS record is still live, and the
    # row is the only record of it, so the offboard is refused.
    with :ok <- release_shared_preview(copy) do
      counts = remove(scope, copy)
      WorkingCopies.released(id)
      {:ok, Map.merge(counts, agents)}
    end
  end

  def offboard(%Scope{}, %WorkingCopy{}), do: {:error, :not_yours}

  defp remove(scope, %WorkingCopy{project_id: project_id, id: id} = copy) do
    Repo.transaction(fn ->
      {files, _} =
        Repo.delete_all(
          from f in CodeMySpec.Files.File,
            where: f.project_id == ^project_id and f.working_copy_id == ^id
        )

      {problems, _} =
        Repo.delete_all(
          from p in CodeMySpec.Problems.Problem,
            where: p.project_id == ^project_id and p.working_copy_id == ^id
        )

      components = reclaim_orphan_components(project_id)
      :ok = WorkingCopies.delete(scope, copy)

      %{files: files, problems: problems, components: components}
    end)
    |> case do
      {:ok, counts} ->
        counts

      {:error, reason} ->
        # Loud, never swallowed: a quiet failure reads as nothing to remove.
        raise "offboard failed for working copy #{id}: #{inspect(reason)}"
    end
  end

  # Anything a file or a story points at is kept; everything else on the
  # project goes. A story-linked component is authored work.
  defp reclaim_orphan_components(project_id) do
    referenced_by_files =
      from f in CodeMySpec.Files.File,
        where: f.project_id == ^project_id and not is_nil(f.component_id),
        select: f.component_id

    referenced_by_stories =
      from s in CodeMySpec.Stories.Story,
        where: s.project_id == ^project_id and not is_nil(s.component_id),
        select: s.component_id

    keep =
      (Repo.all(referenced_by_files) ++ Repo.all(referenced_by_stories))
      |> Enum.uniq()

    {components, _} =
      Repo.delete_all(
        from c in CodeMySpec.Components.Component,
          where: c.project_id == ^project_id and c.id not in ^keep
      )

    components
  end

  defp release_shared_preview(copy) do
    case PreviewTunnel.release(copy) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Staffing] refusing to offboard #{copy.id}: could not release its shared " <>
            "preview: #{inspect(reason)}"
        )

        {:error, {:preview_not_released, reason}}
    end
  end

  # `Projects.ensure_deploy_key/2` mints a key if the project has none. `nil`
  # with no project in scope: the copy joins on what the machine holds. Not
  # rescued — an unexpected shape should be loud.
  defp deploy_key(%Scope{active_project: %Project{} = project} = scope) do
    case Projects.ensure_deploy_key(scope, project) do
      {:ok, %Project{deploy_key: key}} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp deploy_key(%Scope{}), do: nil

  # The host's device: a created copy is on the same filesystem, and recording
  # it keeps two machines' copies at one path apart.
  defp host_device(scope, nil) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.find_value(& &1.device_id)
  end

  defp host_device(_scope, copy_id) do
    case WorkingCopies.fetch(copy_id) do
      {:ok, copy} -> copy.device_id
      _ -> nil
    end
  end

  # Retire (not off: the copy is going away) everything on this copy, and count
  # what would not stop — a process on an unreachable machine is the person's
  # to end.
  defp stop_agents_on(scope, working_copy_id) do
    scope
    |> Agents.list_agents()
    |> Enum.filter(&(&1.working_copy_id == working_copy_id and is_nil(&1.retired_at)))
    |> Enum.reduce(%{agents_stopped: 0, agents_left_running: []}, fn agent, acc ->
      case Agents.retire_agent(scope, agent.id,
             by: Agents.actor(scope),
             reason: "its working copy was offboarded"
           ) do
        {:ok, _stopped} ->
          %{acc | agents_stopped: acc.agents_stopped + 1}

        {:ok, _retired, {:unreachable, machine}} ->
          Logger.warning(
            "[Staffing] offboarding #{working_copy_id}: retired agent #{agent.id}, but " <>
              "#{machine} could not be reached, so its process may still be running"
          )

          %{acc | agents_left_running: [agent.id | acc.agents_left_running]}

        {:error, reason} ->
          Logger.warning(
            "[Staffing] offboarding #{working_copy_id}: could not stop agent " <>
              "#{agent.id} (#{inspect(reason)}); it may still be running"
          )

          %{acc | agents_left_running: [agent.id | acc.agents_left_running]}
      end
    end)
  end
end
