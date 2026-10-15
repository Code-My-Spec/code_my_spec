defmodule CodeMySpec.EpicDispatch do
  @moduledoc """
  The hand-off: an epic the user agreed to build goes to a working copy, and the
  main agent's job turns into reporting on work it is not doing.

  ## Two acts, not one

  The agent proposing and a person approving are two acts. `propose/2` is the
  main agent saying "this set is ready, shall I?"; `approve/2` is the only
  thing that starts work. `ready_for_dev` on a story is a judgement that it is
  shaped, not a trigger.

  ## Act when idle

  `work_to_assign?/1` is the condition behind the `work_dispatched` node: work
  to assign only when **nothing is in progress and unassigned work exists**.
  `dispatch_state/1` answers with a reason rather than a boolean, because
  idle-and-finished and idle-with-work-waiting both look like nothing
  happening.

  ## Reporting is reading, not doing

  `progress/1` answers from what the dispatched side wrote down (`source:
  :record`). A failed epic is a distinct status, because an agent that died and
  one that is thinking both produce nothing.

  See knowledge/agents/coordination, "Epic dispatch".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Conversations,
      CodeMySpec.Epics,
      CodeMySpec.Repo,
      CodeMySpec.Staffing,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ]

  import Ecto.Query, warn: false

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Epics
  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Repo
  alias CodeMySpec.Staffing
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @type dispatch_state :: Epics.dispatch_state()

  @doc """
  Send an epic for approval.

  The main agent's half. Answers `{:error, :not_draft}` for an epic already
  proposed or dispatched — proposing twice would put a second card in front of
  somebody for work they have already been asked about.
  """
  @spec propose(Scope.t(), Ecto.UUID.t()) :: {:ok, Epic.t()} | {:error, term()}
  def propose(%Scope{} = scope, epic_id) do
    with {:ok, epic} <- fetch(scope, epic_id) do
      case epic.status do
        :draft -> save(scope, epic, %{status: :proposed})
        _other -> {:error, :not_draft}
      end
    end
  end

  @doc """
  Agree to build an epic, and hand it to a working copy.

  The only thing that starts work. Where it goes is decided here, never asked
  of the user: a copy already carrying the project's work, else a new one.

  `{:error, :not_proposed}` for anything that was not put in front of the user
  first.
  """
  @spec approve(Scope.t(), Ecto.UUID.t()) :: {:ok, Epic.t()} | {:error, term()}
  def approve(%Scope{} = scope, epic_id) do
    with {:ok, epic} <- fetch(scope, epic_id) do
      case epic.status do
        :proposed -> dispatch(scope, epic)
        _other -> {:error, :not_proposed}
      end
    end
  end

  # An epic with nowhere to go is still dispatched rather than refused: the
  # decision was the user's and it stands; the page reports it as waiting.
  defp dispatch(scope, epic) do
    copy = destination(scope)

    result =
      save(scope, epic, %{
        status: :dispatched,
        dispatched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Placed (on the stories: `place/3`), staffed and assigned, all after the
    # save — the approval stands whether or not agents could be started.
    # Staffing is idempotent by role; product stays on the main copy, and
    # assigning the epic clears its design binding.
    with {:ok, _epic} <- result, %{} <- copy do
      place(scope, epic.id, copy.id)
      Agents.ensure_copy_agents(scope, copy)
      Agents.assign_epic(scope, epic.id, copy.id)
    end

    result
  end

  # A copy already carrying this project's work (its context and agents are
  # there), else a new one; `nil` if neither. Never the main checkout: it does
  # not hold coding or QA seats. Returns the copy: staffing needs its root.
  defp destination(scope) do
    carrying(scope) || minted(scope)
  end

  # Nothing suitable exists, so make one; `nil` on failure (the epic waits).
  defp minted(scope) do
    case Staffing.mint(scope, label: "an epic's working copy") do
      {:ok, copy, _staffed} ->
        copy

      {:error, reason} ->
        Logger.info(
          "[EpicDispatch] no working copy could be made for this epic (#{inspect(reason)}); " <>
            "it is dispatched and waiting for somewhere to be built"
        )

        nil
    end
  end

  # The most recently dispatched epic's copy, when it is a real checkout and not
  # the main one. Most recent because that is the work in flight; a copy that
  # finished an epic months ago is not "where the context already is".
  defp carrying(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    main_id = scope |> WorkingCopies.main() |> then(&(&1 && &1.id))

    from(e in Epic,
      join: s in Story,
      on: s.epic_id == e.id,
      where: e.project_id == ^project_id and not is_nil(s.working_copy_id),
      order_by: [desc_nulls_last: e.dispatched_at],
      select: s.working_copy_id,
      limit: 25
    )
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.reject(&(&1 == main_id))
    |> Enum.find_value(fn id ->
      case WorkingCopies.fetch(id) do
        {:ok, copy} -> checkout(copy)
        _ -> nil
      end
    end)
  end

  defp carrying(%Scope{}), do: nil

  # A row is not a checkout until it reports a root (`ensure_default/1` mints
  # rootless rows).
  defp checkout(%{root: root} = copy) when is_binary(root) and root != "", do: copy
  defp checkout(_copy), do: nil

  @doc """
  Put an epic's stories on a checkout.

  An epic is a convenience for acting on several stories; the graph is grained
  on stories, so the binding is written to `stories.working_copy_id`.

  `update_all` rather than a changeset per story: routing is not a revision of
  the story's content and should not add PaperTrail versions. `updated_at` is
  set by hand.

  Placement edits the queue and preserves stories currently held by agents.
  Passing `nil` returns only unheld stories to the backlog. Approval separately
  assigns the epic to the staffed team through `Agents.assign_epic/3`. The
  team takes one story at a time, together, through `set_active_story` or the
  first claim while the team holds none.

  """
  @spec place(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) :: {:ok, non_neg_integer()}
  def place(%Scope{active_project_id: project_id}, epic_id, working_copy_id)
      when is_binary(project_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    held = held_story_ids(%Scope{active_project_id: project_id})

    {count, _} =
      from(s in Story,
        where: s.epic_id == ^epic_id and s.project_id == ^project_id,
        where: s.id not in ^held
      )
      |> Repo.update_all(set: [working_copy_id: working_copy_id, updated_at: now])

    {:ok, count}
  end

  def place(%Scope{}, _epic_id, _working_copy_id), do: {:ok, 0}

  @doc "Edit a copy's queue without changing its team's current story."
  def edit_queue(%Scope{} = scope, kind, subject, copy_id, action)
      when kind in [:story, :epic] and action in [:add, :remove] do
    with {:ok, copy} <- WorkingCopies.fetch(copy_id),
         true <- copy.project_id == scope.active_project_id,
         true <- is_binary(copy.root) and copy.root != "",
         {:ok, query} <- queue_subject(scope, kind, subject) do
      Repo.transaction(fn -> move_unheld_queue(scope, query, copy_id, action) end)
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp move_unheld_queue(scope, query, copy_id, action) do
    held = held_story_ids(scope)

    query = where(query, [s], s.id not in ^held)

    query =
      if action == :remove, do: where(query, [s], s.working_copy_id == ^copy_id), else: query

    destination = if action == :add, do: copy_id, else: nil
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {count, _} = Repo.update_all(query, set: [working_copy_id: destination, updated_at: now])
    count
  end

  defp held_story_ids(scope) do
    scope
    |> Agents.list_agents()
    |> Enum.filter(&(is_nil(&1.retired_at) and not is_nil(&1.story_id)))
    |> Enum.map(& &1.story_id)
    |> Enum.uniq()
  end

  defp queue_subject(scope, :story, number) do
    case CodeMySpec.Stories.get_story_by_number(scope, number) do
      nil ->
        {:error, :not_found}

      story ->
        {:ok,
         from(s in Story, where: s.id == ^story.id and s.project_id == ^scope.active_project_id)}
    end
  end

  defp queue_subject(scope, :epic, id) do
    case Epics.get_epic(scope, id) do
      nil ->
        {:error, :not_found}

      epic ->
        {:ok,
         from(s in Story,
           where: s.epic_id == ^epic.id and s.project_id == ^scope.active_project_id
         )}
    end
  end

  @doc """
  Record a question a dispatched agent needs the user to answer.

  On the epic's own conversation, keyed `epic:<id>`, not the project's: the
  question belongs beside the work, and the work outlives whichever agent
  holds it.
  """
  @spec record_question(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def record_question(%Scope{} = scope, epic_id, text) when is_binary(text) do
    with {:ok, epic} <- fetch(scope, epic_id),
         {:ok, conversation} <-
           Conversations.find_or_create_session_conversation(
             scope.active_account_id,
             scope.active_project_id,
             "epic:#{epic.id}"
           ) do
      Conversations.add_agent_message(conversation, "coding", "assistant", text)
    end
  end

  @doc """
  Record that a dispatched agent stopped without finishing.

  A status of its own, because silence is also what an agent thinking looks
  like.
  """
  @spec record_failure(Scope.t(), Ecto.UUID.t(), String.t()) :: {:ok, Epic.t()} | {:error, term()}
  def record_failure(%Scope{} = scope, epic_id, reason) when is_binary(reason) do
    with {:ok, epic} <- fetch(scope, epic_id) do
      save(scope, epic, %{status: :failed, failure_reason: reason})
    end
  end

  @doc """
  What the main agent can see about work it dispatched.

  `source: :record` says this came from what the dispatched side wrote down.
  """
  @spec progress(Scope.t()) :: %{epics: [map()], source: :record}
  def progress(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    # Where each epic went, read off its stories; may be several copies.
    # `working_copy_id` is the first by id, for stability.
    copies_by_epic =
      from(s in Story,
        where:
          s.project_id == ^project_id and not is_nil(s.working_copy_id) and
            not is_nil(s.epic_id),
        distinct: true,
        select: {s.epic_id, s.working_copy_id}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    epics =
      Epic
      |> where([e], e.project_id == ^project_id and e.status in [:dispatched, :failed])
      |> order_by([e], asc: e.dispatched_at)
      |> Repo.all()
      |> Enum.map(fn epic ->
        ids = copies_by_epic |> Map.get(epic.id, []) |> Enum.sort()

        %{
          id: epic.id,
          name: epic.name,
          status: to_string(epic.status),
          working_copy_id: List.first(ids),
          working_copy_ids: ids,
          reason: epic.failure_reason
        }
      end)

    %{epics: epics, source: :record}
  end

  def progress(%Scope{}), do: %{epics: [], source: :record}

  @doc "Whether the main agent has work to assign, and why not. See `Epics.dispatch_state/1`."
  defdelegate dispatch_state(scope), to: Epics

  @doc "Whether there is anything for the main agent to do about assignment."
  @spec work_to_assign?(Scope.t()) :: boolean()
  def work_to_assign?(%Scope{} = scope), do: match?({:work_to_assign, _}, dispatch_state(scope))

  @doc "Whether anything dispatched is still being built. See `Epics.in_progress?/1`."
  defdelegate in_progress?(scope_or_project_id), to: Epics

  # Cast before the query (`Repo.get_by/3` raises on a non-UUID, which reads as
  # a broken tool). `:not_found` either way: there is no epic.
  defp fetch(%Scope{active_project_id: project_id}, epic_id) do
    with {:ok, id} <- cast_id(epic_id),
         epic when not is_nil(epic) <- Repo.get_by(Epic, id: id, project_id: project_id) do
      {:ok, epic}
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_), do: :error

  # Through `Epics`, so every transition broadcasts like an edit.
  defp save(scope, epic, attrs) do
    Epics.update_epic(scope, epic, attrs)
  end
end
