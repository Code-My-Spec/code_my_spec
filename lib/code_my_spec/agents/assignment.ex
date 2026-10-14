defmodule CodeMySpec.Agents.Assignment do
  @moduledoc """
  The story and epic a copy's team works on (a31f1cd6).

  The team is the copy's story-scope agents — coding and QA. John: *"the team
  would get assigned a story and see it through to full completion together …
  fine for the team to take a new story from the working copy when the team
  collectively finishes a story."* So a story is assigned to the whole team at
  once and held on each member's `story_id`; that is the only record. The copy
  keeps no story of its own (*"it just blows through"*); a session or product
  reads the team's through `WorkingCopies.team_story_id/1`. The main agent reads
  none and holds none: main is promoted to, never worked on.

  `stories.working_copy_id` stays the checkout reservation: the team's story is
  reserved for its copy, and released when the team moves off it.

  ## How a team gets a story

    * `assign_team/3` — `set_active_story`, from any caller on the copy, or
      from the main agent naming a feature copy.
    * `advance/4` — an explicit assignment's *move*. It locks the team's rows
      so two teammates arriving at once move the team once. No read calls it:
      a team keeps one story until it lands, and landing tells main the team is
      free (criterion 2064) so main assigns the next with `set_active_story`
      (criterion 2065).
    * `claim/3` — a team member starting a story's work when its team holds no
      story assigns that story to the whole team. Starting another story's work
      while the team holds one is refused.
    * A member joining the copy inherits its teammates' story and epic
      (`inherit/2`).
    * `assign_epic/3` — an epic placed on a copy gives its team the epic.

  ## Product's epic

  Product lives on the main copy at epic scope and holds no story (step 4c).
  John: *"Product does an epic's detailed design on the main copy; the
  approved epic then goes to a working copy, where coding and QA build it."*
  So product's `epic_id` is the epic it is designing: set by `claim/3` when it
  starts work on one of that epic's stories, and cleared when the epic is
  placed on a working copy (`assign_epic/3` takes it from every agent not on
  the destination, and product is never there).
  """

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.IssueAssignment
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @doc "Whether `role` is a team member: it works one story with its copy's team."
  @spec team_member?(atom() | String.t() | nil) :: boolean()
  def team_member?(role), do: RoleProfile.scope(role) == :story

  defp team_roles, do: Enum.filter(RoleProfile.roles(), &team_member?/1)

  @doc """
  Assign a story to the whole team on this copy, or clear it with `nil`.

  The story must be ready for development and unassigned or already reserved
  for this copy; an unassigned one is reserved here. Every team member gets it,
  and its epic. The stories the team held before are released unless an agent
  on the copy still holds one. `{:error, :no_team}` when no coding or QA agent
  is on the copy: there is nobody to hold the story. `{:error, :main_copy}` for
  the project's main copy: story work happens on feature copies, and nothing on
  main — not the main agent, not product — ever holds a story.
  """
  @spec assign_team(Scope.t(), Ecto.UUID.t() | nil, term()) ::
          {:ok, integer() | nil} | {:error, term()}
  def assign_team(%Scope{}, nil, _story_id), do: {:error, :no_working_copy}

  def assign_team(%Scope{} = scope, copy_id, story_id) do
    with :ok <- feature_copy(scope, copy_id) do
      fan_out(scope, copy_id, story_id)
    end
  end

  # Story work happens on feature copies. John: "Main is what protects us from
  # dogshit from the agents" — work is promoted to it, never done on it.
  defp feature_copy(scope, copy_id) do
    case WorkingCopies.fetch(copy_id) do
      {:ok, %{project_id: project_id, main: true}} when project_id == scope.active_project_id ->
        {:error, :main_copy}

      {:ok, %{project_id: project_id}} when project_id == scope.active_project_id ->
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  defp fan_out(scope, copy_id, story_id) do
    result =
      Repo.transaction(fn ->
        lock_project(scope)
        team = lock_team(scope, copy_id)
        if team == [], do: Repo.rollback(:no_team)

        story = reserve(scope, copy_id, story_id)
        clear_issue_bag(scope, copy_id, story)
        new_id = story && story.id
        before = team |> Enum.map(& &1.story_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

        from(a in Agent, where: a.id in ^Enum.map(team, & &1.id))
        |> Repo.update_all(set: team_attrs(story))

        still_held = held_on_copy(scope, copy_id)
        Stories.release_stories(scope, copy_id, (before -- [new_id]) -- still_held)

        {before, new_id}
      end)

    with {:ok, {before, new_id}} <- result do
      if before != [new_id], do: WorkingCopies.announce_selection(scope)
      {:ok, new_id}
    end
  end

  defp clear_issue_bag(_scope, _copy_id, nil), do: :ok

  defp clear_issue_bag(scope, copy_id, _story),
    do: IssueAssignment.clear_for_story(scope, copy_id)

  defp lock_project(scope) do
    Repo.one!(
      from p in CodeMySpec.Projects.Project,
        where: p.id == ^scope.active_project_id,
        select: p.id,
        lock: "FOR UPDATE"
    )
  end

  @doc "Release story work when the locked team switches to an issue bag."
  def clear_for_issues(scope, copy_id) do
    team = lock_team(scope, copy_id)

    for agent <- team,
        task <- TaskOwner.tasks(agent),
        not is_nil(task.story_id) and is_nil(task.issue_id),
        task.status in [:active, :prepared, :blocked] do
      {:ok, _} = TaskOwner.complete_task(scope, agent, task.id, :cancelled)
    end

    story_ids =
      Repo.all(
        from s in Stories.Story,
          where: s.project_id == ^scope.active_project_id and s.working_copy_id == ^copy_id,
          select: s.id
      )

    Stories.release_stories(scope, copy_id, story_ids)

    from(a in Agent, where: a.id in ^Enum.map(team, & &1.id))
    |> Repo.update_all(set: [story_id: nil, team_free_at: nil])
  end

  @doc """
  Move the team from its finished story `from_id` onto `to_id`, once.

  Called by an explicit assignment, never by a read (criterion 2064). Teammates
  reading the finished story at the same moment all ask; the team's rows are
  locked first, so the first moves the team and the rest find it no longer on
  `from_id` and do nothing. `{:ok, :moved}` either way, or the assignment's own
  refusal.

  A story that has not landed does not move its team: complete for the coding
  role is not finished while QA is still owed it. Landing is the promotion
  stamp (`stories.promoted_version`), and only a landed story moves the team.
  """
  @spec advance(Scope.t(), Ecto.UUID.t(), integer(), integer()) ::
          {:ok, :moved} | {:error, term()}
  def advance(%Scope{} = scope, copy_id, from_id, to_id) do
    with :ok <- feature_copy(scope, copy_id) do
      Repo.transaction(fn ->
        lock_project(scope)
        team = lock_team(scope, copy_id)
        still_on? = team != [] and Enum.all?(team, &(&1.story_id == from_id))
        move(scope, copy_id, to_id, landed?(scope, from_id) and still_on?)
      end)
    end
  end

  # Read under the same lock as the team's rows, so a promotion cannot land
  # between the check and the move.
  defp landed?(_scope, nil), do: false

  defp landed?(scope, from_id) do
    case Stories.get_story(scope, from_id) do
      %{promoted_version: version} when is_binary(version) -> true
      _unlanded_or_missing -> false
    end
  end

  defp move(_scope, _copy_id, _to_id, false), do: :moved

  defp move(scope, copy_id, to_id, true) do
    case fan_out(scope, copy_id, to_id) do
      {:ok, _id} -> :moved
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reserve(_scope, _copy_id, nil), do: nil

  defp reserve(scope, copy_id, story_id) do
    case Stories.reserve_story(scope, copy_id, story_id) do
      {:ok, story} -> story
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp team_attrs(nil), do: [story_id: nil]
  defp team_attrs(%{id: id, epic_id: nil}), do: [story_id: id, team_free_at: nil]

  defp team_attrs(%{id: id, epic_id: epic_id}),
    do: [story_id: id, epic_id: epic_id, team_free_at: nil]

  defp lock_team(scope, copy_id) do
    from(a in Agent,
      where:
        a.project_id == ^scope.active_project_id and a.account_id == ^scope.active_account_id and
          a.working_copy_id == ^copy_id and a.role in ^team_roles() and is_nil(a.retired_at),
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  @doc """
  What a new team member on a copy takes from its teammates: their story and
  epic. Attributes that already name one are left alone.
  """
  @spec inherit(map()) :: map()
  def inherit(%{working_copy_id: copy_id, role: role} = attrs) when is_binary(copy_id) do
    if team_member?(role) do
      attrs
      |> maybe_put(:story_id, WorkingCopies.team_story_id(copy_id) || retired_team_story_id(copy_id))
      |> maybe_put(:epic_id, team_epic_id(copy_id))
    else
      attrs
    end
  end

  def inherit(attrs), do: attrs

  # A seat filled the moment it is vacated finds no *live* teammate to
  # inherit from -- `WorkingCopies.team_story_id/1` excludes a retired row on
  # purpose, because "retired" means gone and an ordinary read should not
  # surface years-old history for a copy nobody is on. But a seat
  # `retire_agent/3` just freed is not stale history: it is the same work,
  # mid-handoff, and the copy keeps no story of its own to fall back on
  # (John's ruling: "we don't have to record the active story on the copy, it
  # just blows through"). A replacement with no live teammate to inherit from
  # takes the most recently retired team member's story instead of starting
  # unbound -- the shape that left `submit_story_issue` answering
  # `story_not_assigned_to_agent` for work the predecessor had already queued.
  defp retired_team_story_id(copy_id) do
    roles = team_roles() |> Enum.map(&to_string/1)

    from(a in "agents",
      where:
        a.working_copy_id == type(^copy_id, Ecto.UUID) and a.role in ^roles and
          not is_nil(a.retired_at) and not is_nil(a.story_id),
      order_by: [desc: a.retired_at],
      select: a.story_id,
      limit: 1
    )
    |> Repo.one()
  end

  defp maybe_put(attrs, _key, value) when value in [nil, false], do: attrs
  defp maybe_put(attrs, key, value), do: Map.put_new(attrs, key, value)

  @doc "The epic the team on this copy holds, or nil."
  @spec team_epic_id(Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  def team_epic_id(nil), do: nil

  def team_epic_id(copy_id) do
    from(a in Agent,
      where:
        a.working_copy_id == ^copy_id and a.role in ^team_roles() and is_nil(a.retired_at) and
          not is_nil(a.epic_id),
      order_by: [asc: a.inserted_at],
      select: a.epic_id,
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Tell main a team finished a story by promoting it (criterion 1892).

  Release the promoted story and clear only matching active assignments.
  Completed work remains in history; other queued stories remain reserved.
  A repeated or stale landing never clears newer work or repeats the handoff.
  Main receives the standard team-free offer only when no active work remains.
  """
  @spec notify_team_free(Scope.t(), Ecto.UUID.t(), Stories.Story.t()) :: :ok
  def notify_team_free(%Scope{} = scope, copy_id, story) do
    {:ok, freed?} = Repo.transaction(fn -> finish_story(scope, copy_id, story) end)

    if freed? do
      CodeMySpec.Agents.notify_main(scope, :team_free, team_free_message(copy_id, story),
        offer: {:team_free, {"copy", copy_id}}
      )
    end

    :ok
  end

  defp finish_story(scope, copy_id, story) do
    # Share the issue bag mutation lock: a final issue and story can land together.
    Repo.one!(
      from p in CodeMySpec.Projects.Project,
        where: p.id == ^scope.active_project_id,
        select: p.id,
        lock: "FOR UPDATE"
    )

    team = lock_team(scope, copy_id)

    if landed?(scope, story.id) do
      matching = Enum.filter(team, &(&1.story_id == story.id))

      from(a in Agent, where: a.id in ^Enum.map(matching, & &1.id))
      |> Repo.update_all(set: [story_id: nil])

      Stories.release_stories(scope, copy_id, [story.id])
      finish_idle_team(scope, copy_id, matching != [])
    else
      false
    end
  end

  defp finish_idle_team(scope, copy_id, changed?) do
    team = team_on_copy(scope, copy_id)

    free? =
      changed? and Enum.all?(team, &(is_nil(&1.story_id) and is_nil(&1.issue_id))) and
        IssueAssignment.bag(scope, copy_id) == []

    if free? do
      from(a in Agent, where: a.id in ^Enum.map(team, & &1.id))
      |> Repo.update_all(set: [team_free_at: DateTime.utc_now()])
    end

    free?
  end

  @doc """
  Close the `story_promoted` tasks the copy's team still holds on `story`, once
  its promotion has landed. The queue settled it; leaving the task open would
  cost the agent a turn to complete it again.
  """
  @spec close_promotion_tasks(Scope.t(), Ecto.UUID.t(), Stories.Story.t()) :: :ok
  def close_promotion_tasks(%Scope{} = scope, copy_id, %{id: story_id}) do
    for agent <- team_on_copy(scope, copy_id),
        %{requirement_name: "story_promoted", story_id: ^story_id, status: status, id: task_id} <-
          TaskOwner.tasks(agent),
        status in [:active, :prepared, :blocked] do
      {:ok, _} = TaskOwner.complete_task(scope, agent, task_id, :completed)
    end

    :ok
  end

  defp team_on_copy(scope, copy_id) do
    from(a in Agent,
      where:
        a.project_id == ^scope.active_project_id and a.account_id == ^scope.active_account_id and
          a.working_copy_id == ^copy_id and a.role in ^team_roles() and is_nil(a.retired_at)
    )
    |> Repo.all()
  end

  # The notice tells main what to do next, so it must name tools main can
  # actually call. `assign_team/3` is an internal function; the agent-facing
  # route to it is `set_active_story`, which is what `assignment.ex:19`
  # documented all along (issue e21ab16c).
  defp team_free_message(copy_id, story) do
    "Working copy #{copy_id}'s team is free: story #{story.number} (\"#{story.title}\") is " <>
      "promoted and nothing else is assigned to it. Assign it another issue with " <>
      "assign_issue_to_working_copy, or a story with set_active_story."
  end

  @doc """
  The stories agents on this copy hold.
  """
  @spec held_on_copy(Scope.t(), Ecto.UUID.t() | nil) :: [integer()]
  def held_on_copy(%Scope{active_project_id: project_id}, copy_id)
      when is_binary(project_id) and is_binary(copy_id) do
    from(a in Agent,
      where:
        a.project_id == ^project_id and a.working_copy_id == ^copy_id and
          not is_nil(a.story_id) and is_nil(a.retired_at),
      select: a.story_id,
      distinct: true
    )
    |> Repo.all()
  end

  def held_on_copy(%Scope{}, _copy_id), do: []

  @doc """
  Give an epic placed on a copy to the copy's team.

  Agents elsewhere lose it, and with it any of its stories they held: the
  stories now live on another checkout. That includes product, which was
  designing it on the main copy and is not sent with it (step 4c). `nil`
  takes it from everyone, as `EpicDispatch.place/3` returning the stories to
  the backlog does.
  """
  @spec assign_epic(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) :: :ok
  def assign_epic(%Scope{active_project_id: project_id}, epic_id, copy_id)
      when is_binary(project_id) do
    epic_stories = from(s in Stories.Story, where: s.epic_id == ^epic_id, select: s.id)
    elsewhere = from(a in Agent, where: a.project_id == ^project_id)
    elsewhere = if copy_id, do: not_on(elsewhere, copy_id), else: elsewhere

    Repo.transaction(fn ->
      elsewhere
      |> where([a], a.story_id in subquery(epic_stories))
      |> Repo.update_all(set: [story_id: nil])

      elsewhere
      |> where([a], a.epic_id == ^epic_id)
      |> Repo.update_all(set: [epic_id: nil])

      if copy_id do
        from(a in Agent,
          where:
            a.project_id == ^project_id and a.working_copy_id == ^copy_id and
              a.role in ^team_roles() and is_nil(a.retired_at)
        )
        |> Repo.update_all(set: [epic_id: epic_id])
      end
    end)

    :ok
  end

  def assign_epic(%Scope{}, _epic_id, _copy_id), do: :ok

  defp not_on(query, copy_id),
    do: where(query, [a], is_nil(a.working_copy_id) or a.working_copy_id != ^copy_id)

  @doc """
  Whether a team member may start story-level work on `story_id`.

  Its team's own story: yes. Another story while the team holds one: refused,
  so one member never moves off the story its team is seeing through. No story
  yet: the story is assigned to the whole team, and the claim proceeds. Anyone
  who is not a team member is not held to a story; an epic-scope role
  (product) records the story's epic as the one it is designing.
  """
  @spec claim(Scope.t(), Agent.t(), term()) :: :ok | {:error, term()}
  def claim(%Scope{} = scope, %Agent{} = agent, story_id) do
    case {RoleProfile.scope(agent.role), Ecto.Type.cast(:id, story_id)} do
      {:story, {:ok, id}} -> team_claim(scope, agent, id)
      {:epic, {:ok, id}} -> design(scope, agent, id)
      _ -> :ok
    end
  end

  defp team_claim(scope, agent, id) do
    case agent.story_id || WorkingCopies.team_story_id(agent.working_copy_id) do
      ^id -> :ok
      nil -> take(scope, agent, id)
      held -> {:error, {:outside_team_story, held}}
    end
  end

  # Never refuses: which epic product is designing is a record, not a gate.
  # A story placed on another copy went there with its approved epic, so
  # product's work on it (triage, questions) is not designing it (step 4d).
  defp design(scope, agent, id) do
    case Stories.get_story(scope, id) do
      %{working_copy_id: copy} when not is_nil(copy) and copy != agent.working_copy_id ->
        :ok

      %{epic_id: epic_id} when epic_id != agent.epic_id ->
        from(a in Agent, where: a.id == ^agent.id) |> Repo.update_all(set: [epic_id: epic_id])

      _same_or_missing ->
        :ok
    end

    :ok
  end

  # On the main copy nothing holds a story, so a claim there assigns nobody and
  # is not refused for it: story work does not belong on main, but turning a
  # claim away is not where that is decided.
  defp take(scope, agent, id) do
    case assign_team(scope, agent.working_copy_id, id) do
      {:ok, _id} -> :ok
      {:error, :main_copy} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Move one story to another working copy, wherever it is now.

  `EpicDispatch.place/3` moves every story in an epic at once; this is the
  one-story counterpart `stories.working_copy_id` has never had (ae4e748f).
  `Stories.reserve_story/3` only *claims* an unassigned story, and `WorkingCopies.offboard/2`
  releases every story a copy holds, discarding the copy with it -- neither
  takes one story from a copy that still has others.

  Refuses onto a target with no checkout on disk, and refuses to take a
  story out from under the copy whose team has it as the active story
  (`WorkingCopies.team_story_id/1`) unless `force: true` is given -- that is the case
  worth making loud rather than silent, since it would mean the team there
  is mid-work on it.
  """
  @spec move_story(Scope.t(), term(), Ecto.UUID.t(), keyword()) ::
          {:ok, Stories.Story.t()} | {:error, :not_found | :no_checkout | :story_active_elsewhere}
  def move_story(
        %Scope{active_project_id: project_id} = scope,
        story_id,
        target_copy_id,
        opts \\ []
      )
      when is_binary(project_id) do
    force? = Keyword.get(opts, :force, false)

    with {:ok, id} <- Ecto.Type.cast(:id, story_id),
         %{project_id: ^project_id} = story <- Stories.get_story(scope, id),
         {:ok, %{project_id: ^project_id} = target} <- WorkingCopies.fetch(target_copy_id) do
      cond do
        is_nil(target.root) or WorkingCopies.missing?(target) ->
          {:error, :no_checkout}

        not force? and WorkingCopies.team_story_id(story.working_copy_id) == story.id ->
          {:error, :story_active_elsewhere}

        true ->
          Stories.update_story(scope, story, %{working_copy_id: target.id})
      end
    else
      _ -> {:error, :not_found}
    end
  end
end
