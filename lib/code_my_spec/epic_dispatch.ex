defmodule CodeMySpec.EpicDispatch do
  @moduledoc """
  The hand-off: an epic the user agreed to build goes to a working copy, and the
  main agent's job turns into reporting on work it is not doing.

  ## Two acts, not one

  John: *"the agent sending it and the meatbags approving it are two different
  things."* `propose/2` is the first — the main agent saying "this set is ready,
  shall I?". `approve/2` is the second, and it is the only thing that starts
  work. Nothing here collapses them, and `ready_for_dev` on a story stays what
  it always was: a judgement that stories are shaped, not a trigger.

  ## Act when idle, not assign everything

  `work_to_assign?/1` is the condition behind the `work_dispatched` node. John
  corrected his own first version of it:

  > "maybe the condition is actually that there is no ongoing work, so none of
  > the working copies are in progress, and there is no unassigned work ... if
  > an agent is working on our story, the main agent doesn't need to assign more
  > work."

  So there is work to assign only when **nothing is in progress and unassigned
  work exists**. Idle-and-finished and idle-with-work-waiting are both "nothing
  is happening" and only the second wants anybody to act, which is why
  `dispatch_state/1` answers with a reason rather than a boolean.

  ## Reporting is reading, not doing

  `progress/1` answers from what the dispatched side wrote down — `source:
  :record`. That is the point of the hand-off: the main agent reports on work it
  is not doing, and a report it had to run something to produce is the main
  agent doing the work again.

  A failed epic is a distinct status rather than an absence, because an agent
  that died and an agent that is thinking both produce nothing. Story 962 drew
  that line inside one working copy; this is the same line one level up.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Conversations
  alias CodeMySpec.Epics
  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Agents
  alias CodeMySpec.WorkingCopies

  @type dispatch_state ::
          {:work_to_assign, [Epic.t()]}
          | {:nothing_to_assign, :in_progress}
          | {:nothing_to_assign, :all_assigned}

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

  The only thing that starts work. Where it goes is decided here rather than
  asked of the user — John: *"the agent decides. If an existing working copy and
  agent is appropriate it gets assigned there, or a fresh one at the agent's
  discretion."* Knowing which checkout anything is in is what story 963 exists
  to spare somebody.

  `{:error, :not_proposed}` for anything that was not put in front of the user
  first, which is the gate: approving something nobody proposed would mean the
  approval came from somewhere other than the screen it belongs on.
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

  # Which copy the work goes to.
  #
  # The project's main checkout, because that is the one it definitely has and
  # the one already carrying its context — the reuse John described. A copy per
  # epic would mint checkouts until the machine ran out, and choosing between
  # six of them on a path or a last-seen time is the inference story 963's
  # designation rule exists to rule out.
  #
  # An epic with nowhere to go is still dispatched rather than refused: the
  # decision was the user's and it stands. `working_copy_id` is nil until a
  # checkout exists, which the page reports as waiting rather than as an error.
  defp dispatch(scope, epic) do
    copy = destination(scope)

    result =
      save(scope, epic, %{
        status: :dispatched,
        working_copy_id: copy && copy.id,
        dispatched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Staffed on placement, because a copy with an epic and nobody on it is the
    # state this story exists to stop producing. `EpicDispatch.dispatch/2` used
    # to set a status and return — grepping `:dispatched` found the LiveView,
    # the requirement checker and the schema, and no starter (28e838cc).
    #
    # After the save rather than inside it: the placement is the user's decision
    # and it stands whether or not three agents could be started. A provider
    # that is not connected is a reason to report an unstaffed copy, not to
    # refuse an epic somebody agreed to.
    #
    # Idempotent by role, so a second epic onto the same copy starts nothing —
    # the three that are there are the ones that take it.
    with {:ok, _epic} <- result, %{} <- copy do
      Agents.ensure_copy_agents(scope, copy)
    end

    result
  end

  # A checkout, or nothing.
  #
  # The project's main copy when it has one. Not `ensure_default/1`: that mints
  # a rootless nil-object row for writers with no checkout, and sending an epic
  # there made the page say "Being built on your project's checkout" about a
  # directory that does not exist — story 963's defect, reintroduced here after
  # being fixed there. A row is not a checkout until it reports a root.
  #
  # `nil` rather than a refusal, because the user agreed and that stands. The
  # epic is dispatched and waiting for somewhere to be built, which the page
  # says in those words.
  # Returns the copy rather than its id: placing an epic now also staffs it, and
  # `ensure_copy_agents/2` needs the root to start an agent in.
  #
  # A copy already carrying this project's work comes first. John, 2026-08-25:
  # *"the agent decides. If an existing working copy and agent is appropriate —
  # for example I've had you doing all the harness work — it gets assigned
  # there."* Continuity of context is the reason, and it is a real one: the copy
  # that has been doing the harness work knows the harness, and its three agents
  # are already there, so a second epic costs nothing to staff.
  #
  # The main checkout is the fallback and not the preference, which is the
  # opposite of what this did. It answered `WorkingCopies.main/1` for every
  # epic on every project, so a project with a copy dedicated to a body of work
  # sent that work's next epic to the main checkout instead — and staffing it
  # there is refused outright, correctly: the main copy holds one agent and it
  # is the project's own (`Agents.main_copy_is_free/2`). Two agents in one
  # checkout are two processes editing one tree.
  defp destination(scope) do
    carrying(scope) || checkout(WorkingCopies.main(scope))
  end

  # The most recently dispatched epic's copy, when it is a real checkout and not
  # the main one. Most recent because that is the work in flight; a copy that
  # finished an epic months ago is not "where the context already is".
  defp carrying(%Scope{active_project_id: project_id} = scope) when is_binary(project_id) do
    main_id = scope |> WorkingCopies.main() |> then(&(&1 && &1.id))

    from(e in Epic,
      where: e.project_id == ^project_id and not is_nil(e.working_copy_id),
      order_by: [desc_nulls_last: e.dispatched_at],
      select: e.working_copy_id,
      limit: 5
    )
    |> Repo.all()
    |> Enum.reject(&(&1 == main_id))
    |> Enum.find_value(fn id ->
      case WorkingCopies.fetch(id) do
        {:ok, copy} -> checkout(copy)
        _ -> nil
      end
    end)
  end

  defp carrying(%Scope{}), do: nil

  # A row is not a checkout until it reports a root. `ensure_default/1` mints a
  # rootless nil-object row, and sending an epic there made the page say "Being
  # built on your project's checkout" about a directory that does not exist.
  defp checkout(%{root: root} = copy) when is_binary(root) and root != "", do: copy
  defp checkout(_copy), do: nil

  @doc """
  Record a question a dispatched agent needs the user to answer.

  On the epic's own conversation, not the project's. John: *"these other agents
  can come back and ask us questions about business rules and stuff and that'll
  all go into those other sub conversations."*

  The main conversation stays at the level of the project. An agent three layers
  down asking which rate applies is a real question and it belongs beside the
  work that raised it — dropped into the project thread it buries the
  conversation the user and the main agent are actually having, and six agents
  doing it makes that thread unreadable.

  Keyed `epic:<id>`, so the thread belongs to the work rather than to whichever
  agent happens to be holding it. An epic outlives the agent building it —
  that is the whole of story 962's "the record outlives the agent", and a
  question keyed to a process would be lost with it.
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

  A status of its own, because silence is what an agent thinking looks like. Any
  report that cannot tell the two apart says "still going" about work that
  stopped hours ago, and the user finds out by asking why it is taking so long.
  """
  @spec record_failure(Scope.t(), Ecto.UUID.t(), String.t()) :: {:ok, Epic.t()} | {:error, term()}
  def record_failure(%Scope{} = scope, epic_id, reason) when is_binary(reason) do
    with {:ok, epic} <- fetch(scope, epic_id) do
      save(scope, epic, %{status: :failed, failure_reason: reason})
    end
  end

  @doc """
  What the main agent can see about work it dispatched.

  `source: :record` is part of the answer rather than decoration: it says this
  came from what the dispatched side wrote down. A report the main agent had to
  run something to produce is the main agent doing the work again, which is the
  one thing the hand-off exists to stop.
  """
  @spec progress(Scope.t()) :: %{epics: [map()], source: :record}
  def progress(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    epics =
      Epic
      |> where([e], e.project_id == ^project_id and e.status in [:dispatched, :failed])
      |> order_by([e], asc: e.dispatched_at)
      |> Repo.all()
      |> Enum.map(
        &%{
          id: &1.id,
          name: &1.name,
          status: to_string(&1.status),
          working_copy_id: &1.working_copy_id,
          reason: &1.failure_reason
        }
      )

    %{epics: epics, source: :record}
  end

  def progress(%Scope{}), do: %{epics: [], source: :record}

  @doc """
  Whether the main agent has work to assign, and why not when it has none.

  A reason rather than a boolean because the two ways of having nothing to do
  mean opposite things. Nothing in progress and nothing left is a finished
  project; nothing in progress with work waiting is the one state that wants
  somebody to act, and a node that reported them the same way would either nag a
  finished project forever or go quiet on one that is stuck.
  """
  @spec dispatch_state(Scope.t()) :: dispatch_state()
  def dispatch_state(%Scope{active_project_id: project_id} = scope)
      when is_binary(project_id) do
    cond do
      in_progress?(project_id) -> {:nothing_to_assign, :in_progress}
      unassigned(scope) == [] -> {:nothing_to_assign, :all_assigned}
      true -> {:work_to_assign, unassigned(scope)}
    end
  end

  def dispatch_state(%Scope{}), do: {:nothing_to_assign, :all_assigned}

  @doc "Whether there is anything for the main agent to do about assignment."
  @spec work_to_assign?(Scope.t()) :: boolean()
  def work_to_assign?(%Scope{} = scope), do: match?({:work_to_assign, _}, dispatch_state(scope))

  # Anything dispatched and not finished. A failed epic is not in progress —
  # that is the distinction `record_failure/3` exists to make, and counting it
  # as busy would leave a project that fell over reporting itself as working.
  defp in_progress?(project_id) do
    Repo.exists?(from e in Epic, where: e.project_id == ^project_id and e.status == :dispatched)
  end

  # Stories that are ready and belong to no epic. Ready matters: an unshaped
  # story is not work waiting to be assigned, it is work waiting to be shaped,
  # and proposing it would put the wrong thing in front of somebody.
  defp unassigned(%Scope{active_project_id: project_id}) do
    Story
    |> where([s], s.project_id == ^project_id and s.ready_for_dev == true and is_nil(s.epic_id))
    |> Repo.all()
  end

  # Cast before the query, because `Repo.get_by/3` raises on an id that is not a
  # UUID rather than answering nil — and the raise reaches an agent as a dump of
  # the Ecto query, which reads like a broken tool rather than a bad argument.
  #
  # `:not_found` for both, deliberately. To the caller "that is not an epic id"
  # and "no epic has that id" are the same fact — there is no epic — and two
  # answers would only invite an agent to try casting the string differently.
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

  # Through `Epics` rather than straight to the repo, so every transition
  # broadcasts the way an edit does. The epics screen is where the user watches
  # the main agent work — an epic that only appears on reload is a report
  # rather than something being watched.
  defp save(scope, epic, attrs) do
    Epics.update_epic(scope, epic, attrs)
  end
end
