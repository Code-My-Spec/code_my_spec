defmodule CodeMySpec.Staffing do
  @moduledoc """
  A working copy and the agents on it, changed together.

  `WorkingCopies` records copies; `Agents` runs the agents that work in them.
  Three acts touch both — making a copy and staffing it, moving the main
  designation and the main agent with it, and offboarding a copy and ending its
  agents — and they live here so that neither context has to call the other.
  Until 2026-09-27 they lived in `WorkingCopies`, which made it and `Agents`
  depend on each other.
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
    ],
    exports: :all

  require Logger

  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Transport
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
  def handle_event(@gate_copy_needed, _measurements, %{scope: scope, label: label}, _config) do
    case mint(scope, label: label, roles: []) do
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

  Here rather than in the MCP tool because it has two callers with nothing else
  in common — an agent asking for somewhere to work, and `EpicDispatch` placing
  an epic that has nowhere to go. A tool cannot be the home of that: `McpServers`
  depends on this boundary and not the other way round, so `EpicDispatch` calling
  the tool would be the dependency backwards.

  Answers `{:ok, copy, staffed}` where `staffed` is `ensure_copy_agents/2`'s
  report, so the caller can say which agents came up and which did not. A copy
  that could not be staffed is still a copy: the checkout exists and the failure
  belongs in front of somebody, not in a rollback.
  """
  @spec mint(Scope.t(), keyword()) ::
          {:ok, WorkingCopy.t(), map()} | {:error, term()}
  def mint(%Scope{active_project_id: project_id} = scope, opts \\ [])
      when is_binary(project_id) do
    # Only copies that are checkouts. A row is not one until it reports a root —
    # `ensure_default/1` mints a rootless nil-object row — and a machine is only
    # a candidate host if it actually holds the repository.
    # The main checkout first, then anything else that is a checkout.
    #
    # Order matters and it is not a preference. A new copy is made *beside* the
    # host — `.claude/worktrees/<name>` under its root — so a host that is
    # itself a worktree nests one inside another. Run live once, the first copy
    # this made landed at
    # `…/worktrees/agent-conversation-ui/.claude/worktrees/live-smoke-test-one`,
    # because `host_holder/1` takes whichever candidate is connected and the
    # list happened to start with a worktree.
    #
    # The main checkout is the one place a sibling is a sibling. Everything else
    # stays in the list because a project whose main copy is not connected
    # should still be able to make one, and a nested worktree is worse than no
    # worktree only in tidiness — it still works.
    copies =
      scope
      |> WorkingCopies.list_harnesses()
      |> Enum.filter(&(is_binary(&1.root) and &1.root != ""))

    candidates =
      copies
      |> Enum.sort_by(& &1.main, :desc)
      |> Enum.map(& &1.id)

    request = %{
      "project_id" => project_id,
      # The identity travels *to* the harness rather than back from it, so the
      # file on disk and the row here hold one value rather than two derivations
      # of it — the failure story 891 exists to end.
      "working_copy_id" => Ecto.UUID.generate(),
      "label" => opts[:label],
      "root" => opts[:root],
      # A copy that cannot authenticate is a copy that never joins, so the key
      # goes with it. `ensure_deploy_key/2` mints one if the project has none —
      # a new project does not get one at creation, and everything that must
      # authenticate as the project has to ask for it first.
      "deploy_key" => opts[:deploy_key] || deploy_key(scope)
    }

    with {:ok, %{root: root, working_copy_id: id} = made} <-
           Transport.impl().create_working_copy(candidates, request, 60_000),
         {:ok, copy} <-
           WorkingCopies.issue(scope, id,
             root: root,
             label: opts[:label],
             device: host_device(scope),
             # Not a suggestion. This id is already written into the checkout's
             # own config, and a row under a different one is a copy nothing can
             # recognise.
             working_copy_id: id
           ),
         {:ok, copy} <- WorkingCopies.report_root(copy, root) do
      # `:setup` rides along on the staffing map rather than widening the
      # `{:ok, copy, staffed}` contract. It says whether the project set the copy
      # up through its own `init-worktree` recipe or whether the harness fell back
      # to a bare worktree — which the caller has to be told, because a bare copy
      # has no deps, no `_build` and no untracked config, and every failure that
      # follows looks like something else.
      staffed =
        scope
        |> Agents.ensure_copy_agents(copy, opts[:roles] || Agents.copy_roles())
        |> Map.put(:setup, Map.get(made, :setup))

      {:ok, copy, staffed}
    end
  end

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
      # The agent goes where the designation goes. A project whose main copy
      # is one checkout and whose main agent is running in another satisfies
      # nobody: the page names one place and the work happens in the other.
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

  ## Why this is an act and not a sweep

  It used to happen on its own, to any copy quiet longer than a configured
  window, riding on whichever agent next synced components. That model is gone.
  It could not tell a checkout that had been deleted from an agent that was
  simply busy, because the only thing it had to go on was elapsed time — and it
  got that wrong in the expensive direction, reading two mid-session harnesses
  as 2:21 and 2:25 idle against a two hour window.

  What replaced it: the harness says whether the path is still there, that shows
  up as a warning, and a person decides. The cost is that an orphan blocks until
  somebody clears it. That is the better failure — a visible thing waiting for a
  click, rather than an invisible one deleting a working agent's state.

  ## Why the row goes too

  The old rule kept it, on the argument that identity lives in
  `.cms_harness.json` so a returning agent presents the id it always had. A
  removed checkout took that file with it, so there is nothing left to present
  and nothing to come back to. A copy that reappears at the same path is
  onboarded, which mints a new id — see 891.

  ## What it never does

  Touch the checkout. The row is ours and the directory is not, and a server
  that deletes somebody's files because they clicked a button in a list is not a
  trade anyone asked for. Offboarding a copy whose checkout still exists leaves
  it exactly where it is, config file and all — it will simply not be recognised
  until it onboards again.
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
    # The agents first, and outside the transaction, because stopping one is a
    # request to a machine rather than a write.
    #
    # A copy is the boundary of the work — story 964's rule, John: "I can keep
    # them through that whole epic and then I can discard the working copy". So
    # discarding has to end them, and an agent that outlived its checkout would
    # be a model held open against a directory that is not there, still holding
    # a subscription slot and still spending. Story 961 is the same concern
    # arriving from the other side.
    #
    # Best-effort, and it does not block the offboard. The copy this is most
    # often used on is one whose machine has gone — that is story 892's whole
    # premise — and refusing to let go of a checkout because nothing can be
    # reached to stop an agent on it would make the vanished case unofboardable,
    # which is the one case the control exists for.
    agents = stop_agents_on(scope, id)

    # Not best-effort, unlike the above: releasing a shared preview talks to
    # Cloudflare, never to the copy's own machine, so "the machine is gone" —
    # the case the leniency above exists for — cannot make this fail. A
    # failure here means the ingress rule or the DNS record is still live,
    # and deleting the row anyway would erase the one place that remembers
    # either exists to clean up — a hostname kept serving whatever now runs
    # on that port, with nothing left to notice or release it. Refusing loudly
    # and leaving the row in place is what keeps that state findable.
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
        # Loud, never swallowed. An offboard that fails quietly leaves the orphan
        # in place and reports success, which is indistinguishable from one that
        # had nothing to remove.
        raise "offboard failed for working copy #{id}: #{inspect(reason)}"
    end
  end

  # Two plain subqueries rather than correlated `exists`. The component set is
  # small and this is legible: anything a file or a story points at is kept,
  # everything else on the project goes.
  #
  # The story link is the one that matters. A component somebody wrote a story
  # against is authored work, and spending it to clear derived rows would make
  # this destructive in a way no warning covers.
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

  # `ensure_deploy_key/2` takes the project and answers the project, minting a
  # key onto it if it has none — a new project does not get one at creation, and
  # everything that must authenticate as the project has to ask first.
  #
  # `nil` when there is no project in scope to ask about, which the harness
  # handles: the copy is written without a key and joins on whatever the machine
  # already holds. Not rescued — an unexpected shape here should be loud, and
  # the version this replaced swallowed a FunctionClauseError for a whole
  # session.
  defp deploy_key(%Scope{active_project: %Project{} = project} = scope) do
    case Projects.ensure_deploy_key(scope, project) do
      {:ok, %Project{deploy_key: key}} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp deploy_key(%Scope{}), do: nil

  # The machine the host copy is on. A created copy sits on the same filesystem
  # as the checkout it was made beside, so it is on the same device — and
  # recording that is what stops two machines' copies at one path being confused.
  defp host_device(scope) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.find_value(& &1.device_id)
  end

  # Retire everything on this copy, and say what would not stop. Retired, not
  # off: the copy is going away, so its agents are gone for good (39af5611).
  #
  # Counted rather than swallowed: "3 agents stopped" and "3 agents stopped, 1
  # still running" are different facts and the person offboarding needs the
  # second one, because the remedy is theirs — a process on a machine we could
  # not reach is not something the server can end on its own.
  defp stop_agents_on(scope, working_copy_id) do
    scope
    |> Agents.list_agents()
    |> Enum.filter(&(&1.working_copy_id == working_copy_id and &1.status != :stopped))
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
