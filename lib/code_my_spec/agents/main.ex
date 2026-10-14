defmodule CodeMySpec.Agents.Main do
  @moduledoc """
  The agent that owns a project, and the view across everything working in it.

  `CodeMySpec.Agents` owns an agent — start it, stop it, deliver it a message.
  This owns the judgement *about* them: what every agent in every checkout is
  waiting on, which of it the main agent can settle itself, and which of it is
  worth a person's attention. One is a lifecycle, the other is a position, and
  the position is a project's rather than a checkout's.

  ## A question has a holder

  `status` says whether a question is finished, not who it is with. An agent's
  question starts held by the main agent (or product, for criteria questions),
  and escalating moves the holder rather than closing the question, so main
  sees only what still needs it and the person sees what reached them.

  See knowledge/agents, "Questions".
  """

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Cadence
  alias CodeMySpec.Agents.Main.CheckInReport
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.Main.GapRepository
  alias CodeMySpec.Agents.Main.Machinery
  alias CodeMySpec.Agents.Main.MachineryRepository
  alias CodeMySpec.Agents.Main.OpenQuestion
  alias CodeMySpec.Agents.Main.QuestionsRepository
  alias CodeMySpec.Agents.Main.RestartRepository
  alias CodeMySpec.Agents.Main.WorkRepository
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Conversations
  alias CodeMySpec.Issues
  alias CodeMySpec.Notifications
  alias CodeMySpec.Questions
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.Utils.Utf8
  alias CodeMySpec.WorkingCopies

  @doc """
  Everything this project's agents are waiting on, wherever they are running.

  Oldest first, answered ones gone. Questions and permissions both, since both
  stop an agent identically.
  """
  @spec list_open_questions(Scope.t()) :: [OpenQuestion.t()]
  defdelegate list_open_questions(scope), to: QuestionsRepository

  @doc """
  What every running agent on this project is doing, across all its checkouts.

  Parts rather than a verdict: the caller decides what a silence means.

  Reading it also settles restart records and raises a fault for each restart
  that changed nothing (`review_restarts/2`).
  """
  @spec list_agent_work(Scope.t()) :: [AgentWork.t()]
  def list_agent_work(%Scope{} = scope) do
    work = WorkRepository.list_agent_work(scope)
    :ok = review_restarts(scope, work)
    work
  end

  @doc "Agents somebody turned off. Shown so the main agent leaves them off."
  @spec list_off_agents(Scope.t()) :: [Agent.t()]
  defdelegate list_off_agents(scope), to: Agents, as: :off_agents

  # Looking is when a failed remedy is noticed, because nothing else looks. A
  # write during a read, on purpose: settling is idempotent and a fault is
  # filed once while open (`raise_fault/4`).
  defp review_restarts(scope, work) do
    Enum.each(work, fn entry ->
      :ok = RestartRepository.settle(entry)

      entry
      |> RestartRepository.unresolved_reasons()
      |> Enum.each(&report_failed_remedy(scope, entry, &1))
    end)
  end

  defp report_failed_remedy(scope, entry, reason) do
    raise_fault(
      scope,
      entry.working_copy_root,
      titled("A restart changed nothing", reason),
      """
      The #{entry.role} agent #{entry.agent_id} was restarted for this and the fault is \
      still here:

        #{reason}

      Restarting is the wrong remedy. Treat it as a bug to be fixed rather than \
      a state to be managed — something is wrong that restarting does not reach.
      """
    )
  end

  @doc """
  The state of everything this project's agents depend on.

  The answer to "is it the agent or is it the machine". A machine-wide tool
  fault is raised as an issue when found.
  """
  @spec check_machinery(Scope.t()) :: Machinery.t()
  def check_machinery(%Scope{} = scope) do
    machinery = MachineryRepository.check(scope)
    :ok = report_machinery_fault(scope, machinery)
    machinery
  end

  # Raised when found, not when somebody next restarts something. Only the
  # machine-wide case: one agent's fault is within main's reach, and filing it
  # would be raising everything and fixing nothing.
  defp report_machinery_fault(scope, %Machinery{tool_fault: :machine} = machinery) do
    raise_fault(
      scope,
      root_of(machinery),
      "The machinery is serving no tools",
      """
      Every agent on this project is on a machine reporting an empty tool list, \
      so every tool call any of them makes will fail. This is one fault \
      underneath them rather than several agents in trouble.

      Restarting the agents will not reach it — they come back into the same \
      client. Clearing it means restarting the harness, which serves every \
      working copy on that machine and is not the main agent's to restart.
      """
    )

    :ok
  end

  defp report_machinery_fault(_scope, %Machinery{}), do: :ok

  defp root_of(%Machinery{copies: copies}) do
    case Enum.find(copies, &(&1.machine_tools == [])) do
      nil -> nil
      copy -> copy.root
    end
  end

  @doc """
  Restart one of this project's agents, saying why.

  The reason is required and is the whole mechanism: restarts are recorded per
  agent and reason, so the record says what has already been tried and whether
  it worked.

  ## The answers

  `{:ok, agent}` — restarted, recorded with its reason on the agent's own
  thread, and the reason sent to the agent.

  `{:error, :not_mine}` — the id does not name an agent of this project (a
  working copy, a harness, another project's agent). Raised as an issue: a
  harness restart would kill in-flight work on every checkout on the machine,
  so somebody who can weigh that decides.

  `{:error, :machinery_faulty}` — every agent's machine is serving no tools; a
  restart cannot reach that. Refused and raised.

  `{:error, {:already_tried, n}}` — this reason has been tried `n` times
  (`@restart_limit`) and the agent has not been seen working since. Refused and
  raised. A restart whose predecessor did not work is allowed, and that failed
  remedy is raised as it is noticed.

  `{:error, {:off, agent}}` — somebody turned it off. Refused before anything
  else is weighed; `turn_on_agent` is the only way back.

  `{:error, :needs_a_reason}` — no reason given.
  """
  @spec restart_agent(Scope.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error,
             :not_mine
             | :needs_a_reason
             | :machinery_faulty
             | {:already_tried, pos_integer()}
             | {:off, Agent.t()}}
  def restart_agent(%Scope{} = scope, agent_id, reason)
      when is_binary(reason) and reason != "" do
    case mine(scope, agent_id) do
      {:ok, agent} ->
        with :ok <- Agents.refuse_unless_on(agent) do
          :ok = RestartRepository.settle(agent)
          consider(scope, agent, reason)
        end

      {:error, :not_mine} ->
        out_of_reach(scope, agent_id, reason)
    end
  end

  def restart_agent(%Scope{}, _agent_id, _reason), do: {:error, :needs_a_reason}

  # A fault underneath the agent is not one a restart reaches, and it is known
  # before the first attempt: the agent would come back into the same dead
  # client, indistinguishable from one slow to recover.
  defp consider(scope, agent, reason) do
    scope
    |> check_machinery()
    |> Map.get(:tool_fault)
    |> decide(scope, agent, reason)
  end

  defp decide(:machine, scope, agent, reason) do
    raise_fault(
      scope,
      agent.working_copy,
      titled("The machinery is what is broken", reason),
      """
      Every agent on this project is on a machine reporting no tools, so this is \
      one fault underneath them rather than an agent that needs restarting:

        #{reason}

      Restarting was refused. An agent restarted into the same client comes back \
      into the same fault, and the attempt is indistinguishable from an agent \
      that is merely slow to recover. `check_machinery` has the detail.
      """
    )

    {:error, :machinery_faulty}
  end

  defp decide(_fault, scope, agent, reason) do
    attempt(scope, agent, reason, RestartRepository.unresolved(agent, reason))
  end

  # How much of an agent's conversation one read hands back: a turn count for
  # the common read, and a byte budget, because one tool result can outweigh
  # fifty ordinary turns.
  @conversation_turn_limit 50
  @conversation_byte_budget 20_000

  # How far back a narrowing read looks. Only paid when `since`, `until` or
  # `last_call_of` is given, since a plain read wants the recent end anyway.
  @conversation_search_depth 500

  @restart_limit 3

  defp attempt(scope, agent, reason, tried) when length(tried) >= @restart_limit do
    raise_fault(
      scope,
      agent.working_copy,
      titled("Restarting is not fixing this", reason),
      """
      #{agent.role} agent #{agent.id} has been restarted #{length(tried)} times for the same \
      reason and has not been seen working after any of them:

        #{reason}

      Further restarts are refused. This is a bug to be fixed rather than a \
      state to be managed — something is wrong that restarting does not reach.
      """
    )

    {:error, {:already_tried, length(tried)}}
  end

  defp attempt(scope, agent, reason, _tried) do
    with {:ok, restarted} <- Agents.restart_agent(scope, agent.id),
         {:ok, _restart} <- RestartRepository.record(agent, reason) do
      # Recorded on the thread whether or not the notice reaches the agent.
      Conversations.record_restart(restarted, reason)

      # The agent must also receive the reason through the measured queue.
      Agents.send_to_agent(restarted.id, "Restarted: #{reason}", :own_reply,
        offer: {:resume, {"restart", nil}}
      )

      {:ok, restarted}
    end
  end

  # A refusal is converted into a decision for somebody who can make it; one
  # that tells nobody is worse than the action.
  defp out_of_reach(scope, target, reason) do
    Issues.create_issue(scope, %{
      title: titled("An agent fault needs something outside the project", reason),
      severity: :high,
      scope: :framework,
      description: """
      The main agent tried to restart `#{target}`, which is not one of this \
      project's agents, for:

        #{reason}

      It was refused. If the remedy is a harness restart it is not the main \
      agent's to perform — it is a shared harness, serving every working copy on \
      that machine and other projects with it, so restarting it takes their \
      in-flight work too. Somebody who can weigh that needs to decide.
      """
    })

    {:error, :not_mine}
  end

  # An agent of this project, and nothing else: `Agents.fetch_agent/2` is
  # project-scoped, so any other id lands as `:not_mine`.
  defp mine(scope, agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} -> {:ok, agent}
      {:error, _reason} -> {:error, :not_mine}
    end
  end

  # The reason belongs in the title: `list_issues` shows titles, and the fault
  # is the only part that differs between entries.
  defp titled(what, reason), do: "#{what}: #{String.slice(reason, 0, 120)}"

  # Raised as a framework issue, once per fault: keyed on the title while an
  # issue with it is open. The cadence keeps re-noticing a fault until a person
  # deals with it; after a dismiss or resolve, a recurrence is news.
  defp raise_fault(scope, working_copy, title, description) do
    file_fault(Issues.open_issue_titled?(scope, title), scope, working_copy, title, description)
  end

  defp file_fault(true, _scope, _working_copy, title, _description) do
    Logger.info("[MainAgent] fault already raised, not filing again: #{title}")
    {:ok, :already_raised}
  end

  defp file_fault(false, scope, working_copy, title, description) do
    Issues.create_issue(scope, %{
      title: title,
      severity: :high,
      scope: :framework,
      description: description,
      source_path: working_copy
    })
  end

  @doc """
  Wake the main agent and hand it what is going on.

  Builds the digest (or takes one built) and renders it as the check-in
  report — the answer, not an instruction to go and assemble one — and offers
  this project's agents a recovery-check turn. A digest that could not be
  built is raised as a fault and returned as `{:error, reason}`, never rendered
  as an all-quiet report.
  """
  @spec check_in(Scope.t()) :: {:ok, String.t()} | {:error, String.t()}
  def check_in(%Scope{} = scope), do: check_in(scope, Cadence.digest(scope))

  @doc "`check_in/1` on a digest already built."
  @spec check_in(Scope.t(), Digest.t()) :: {:ok, String.t()} | {:error, String.t()}
  def check_in(%Scope{} = scope, %Digest{} = digest), do: deliver_check_in(scope, digest)

  @doc "How often this project's main agent is woken, in seconds."
  @spec cadence_interval(Scope.t()) :: pos_integer()
  defdelegate cadence_interval(scope), to: Cadence, as: :interval

  @doc "Set how often this project's main agent is woken."
  @spec set_cadence_interval(Scope.t(), pos_integer()) :: :ok
  defdelegate set_cadence_interval(scope, seconds), to: Cadence, as: :set_interval

  @doc """
  Whether this project's main agent is still meant to be woken.

  Intent. Answers "has it stood down", and says nothing about whether a timer
  exists — see `cadence_alive?/1` for that.
  """
  @spec cadence_running?(Scope.t()) :: boolean()
  defdelegate cadence_running?(scope), to: Cadence, as: :running?

  @doc "Whether a cadence timer actually exists for this project right now."
  @spec cadence_alive?(Scope.t()) :: boolean()
  defdelegate cadence_alive?(scope), to: Cadence, as: :alive?

  defdelegate last_recovery_check(scope), to: Cadence, as: :last_check

  @doc "Start this project's cadence if it is not already running."
  @spec ensure_cadence(Scope.t()) :: {:ok, pid()} | {:error, term()}
  defdelegate ensure_cadence(scope), to: Cadence, as: :ensure_running

  @doc """
  Re-establish cadences for every project with an on-duty `main` agent.

  The application's boot seeding calls this. On the context because `Cadence`
  is inside this boundary and the web app is outside it.
  """
  @spec wake_active_projects() :: :ok
  defdelegate wake_active_projects, to: Cadence

  defp deliver_check_in(scope, %Digest{failed: reason} = digest) when is_binary(reason) do
    # Raised, not delivered as an empty all-quiet: the empty one says what a
    # healthy fleet says, for as long as whatever broke stays broken.
    raise_fault(
      scope,
      nil,
      "The check-in could not be assembled",
      """
      The cadence came round and the digest could not be built:

        #{reason}

      Nothing was delivered to the main agent, because an empty digest reads as \
      all-quiet and would go on doing so every interval until this is fixed.
      """
    )

    _ = digest
    {:error, reason}
  end

  defp deliver_check_in(scope, %Digest{} = digest) do
    :ok = Work.consider_project(scope, :recovery_check)
    {:ok, CheckInReport.render(digest)}
  end

  @doc """
  The cadence's tick: a turn for a continuous main with work or attention,
  carrying the check-in and its own work offer together, and the recovery
  check for every other agent.

  Never a nudge for a non-continuous main: the turn goes through `Wake` as
  `:cadence`, which holds a non-continuous main, one waiting on its own run,
  and one mid-turn (skipped, not queued). Every main is left out of the
  recovery check, so one tick is at most one turn. A stood-down main gets
  nothing from the timer.

  `newly_stalled` are teammates that stalled since the last tick. They ride in
  the turn; when no turn goes, they are announced on their own
  (`:teammate_stalled`), which still reaches a main that is mid-turn.

  Answers `{:ok, ref}` when the turn went, otherwise why not.
  """
  @spec cadence_check_in(Scope.t(), Digest.t(), [AgentWork.t()]) ::
          {:ok, term()} | {:error, term()}
  def cadence_check_in(%Scope{} = scope, %Digest{failed: reason} = digest, _newly_stalled)
      when is_binary(reason),
      do: deliver_check_in(scope, digest)

  def cadence_check_in(%Scope{} = scope, %Digest{} = digest, newly_stalled) do
    # The main checkout's, as `notify_main` resolves it, so a tick and a stall
    # notice never name different mains.
    main = if Cadence.running?(scope), do: Agents.main_agent(scope)
    result = cadence_turn(scope, main, digest, newly_stalled)
    # Every main is the cadence's, whatever its status: the recovery check is
    # for everyone else.
    mains = scope |> Agents.list_agents() |> Enum.filter(&(&1.role == :main))
    :ok = Work.consider_project(scope, :recovery_check, Enum.map(mains, & &1.id))

    case result do
      {:ok, ref} when is_binary(ref) -> :ok
      _no_turn -> :ok = Cadence.announce_stalls(scope, newly_stalled)
    end

    result
  end

  defp cadence_turn(_scope, nil, _digest, _newly_stalled), do: {:ok, :no_main}

  defp cadence_turn(scope, %Agent{} = main, digest, newly_stalled) do
    new_stalls = Enum.map(newly_stalled, & &1.agent_id)

    Work.request_cadence_turn(
      scope,
      main,
      fn work? ->
        CheckInReport.render(digest, self: main.id, work?: work?, new_stalls: new_stalls)
      end,
      attention?: CheckInReport.needs_attention?(digest)
    )
  end

  @doc """
  Answer one of this project's open questions from what the project records.

  `opts`: `:basis` (`"record"`, `"precedent"` with `:precedent_id`, or
  `"inspected"` with `:inspector_id` and `:citation`), `:by` (`:product` for
  the product agent answering its own), `:on_behalf_of` and `:tool`, and
  `:worked_around`. An answer that does not stand up is escalated to the user
  and the error returned.

  See knowledge/agents, "Answering questions".

  ## Refused when it would be a way round a role's own limits

  `on_behalf_of` and `tool` name a request to act as somebody else. A role
  that does not carry the tool does not get it used on its behalf, or every
  scoping decision in `ToolSets` would be advisory.

  ## `worked_around` is how a gap gets counted

  Only the answerer knows whether an answer was a workaround, so it says, and
  the counting is ours: a capability gap per role, filed once as an issue.
  """
  @spec answer_question(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def answer_question(%Scope{} = scope, question_id, answer, opts \\ []) do
    with {:ok, question} <- QuestionsRepository.fetch_open_question(scope, question_id),
         :ok <- answerable(question) do
      answer_as(Keyword.get(opts, :by), scope, question, answer, opts)
    end
  end

  # The product agent answers the criteria questions routed to it as their
  # owner: its answer is the decision, as the user's is, so it is not weighed
  # against the records. Only its own.
  defp answer_as(:product, scope, %{holder: "product_agent"} = question, answer, opts),
    do: settle(scope, question, answer, Keyword.put(opts, :answered_by, "product_agent"))

  defp answer_as(:product, _scope, _question, _answer, _opts), do: {:error, :not_yours}

  # Routed straight to the user from the start: only the user settles it. One
  # main escalated carries an `escalation_reason` and stays answerable.
  defp answer_as(_role, _scope, %{holder: "user", escalation_reason: nil}, _answer, _opts),
    do: {:error, :with_user}

  defp answer_as(_main, scope, question, answer, opts) do
    case within_scope(question, opts) do
      :ok -> weigh(scope, question, answer, opts)
      refusal -> refusal
    end
  end

  # A permission is not answerable with prose; `decide_permission/4` settles it.
  # The queue unions both, so `fetch_open_question/2` can hand one over.
  defp answerable(%{kind: :permission}), do: {:error, :is_permission}
  defp answerable(_question), do: :ok

  @doc """
  Settle one entry from the queue, whichever kind it is.

  The queue unions two things that stop an agent identically
  (`Notifications.awaiting_answer?/1`), settled by different verbs: a question
  takes an answer and a basis; a permission takes `allow` or `deny`. One
  definition of "settle this" here keeps every surface in step.

  A permission must belong to an agent of this project. `:not_found`
  otherwise — the same answer an unknown id gets, deliberately.
  """
  @spec decide_permission(Scope.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def decide_permission(scope, permission_id, decision, answer \\ nil)

  def decide_permission(%Scope{} = scope, permission_id, decision, answer)
      when decision in ~w(allow deny) do
    case QuestionsRepository.fetch_open_permission(scope, permission_id) do
      {:ok, _entry} -> Notifications.resolve_permission_request(permission_id, decision, answer)
      {:error, reason} -> {:error, reason}
    end
  end

  def decide_permission(%Scope{}, _permission_id, decision, _answer),
    do: {:error, {:unknown_decision, decision}}

  # An answer that does not stand up sends the question on to the user — one
  # left with main would be absorbed with no symptom anywhere — and the error
  # still comes back, so main does not believe the asker is unblocked.
  defp weigh(scope, question, answer, opts) do
    case stands_up?(scope, question, answer, opts) do
      {:ok, basis} ->
        settle(scope, question, attribute(answer, basis), opts)

      {:error, reason} ->
        :ok = escalate_unless_with_user(scope, question, reason)
        {:error, reason}
    end
  end

  # Main may answer a question already with the user. One it cannot stand up
  # stays as it was, with the reason it was sent up.
  defp escalate_unless_with_user(_scope, %{holder: "user"}, _reason), do: :ok

  defp escalate_unless_with_user(scope, question, reason) do
    {:ok, _escalated} = escalate_question(scope, question.id, why(reason))
    :ok
  end

  defp why(:no_basis),
    do: "the main agent had nothing to base an answer on, so this is yours to decide"

  defp why(:not_recorded),
    do: "the project does not record an answer to this, so it is yours to decide"

  defp why(:no_precedent),
    do: "no earlier decision of yours covers this"

  defp why(:no_citation),
    do: "the main agent had nothing to cite from its own reading, so this is yours to decide"

  defp why({:not_inspected, citation}),
    do:
      "the main agent cited #{inspect(citation)}, which does not match anything in its own " <>
        "session, so this is yours to decide"

  defp why(reason), do: "the main agent could not answer this: #{inspect(reason)}"

  @doc """
  The main agent gives up on a question it could not answer.

  Escalation with the trying written into the reason. Without it a question
  main took and could not settle would stay with it, absorbed, with no symptom
  on any surface.
  """
  @spec give_up_on_question(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def give_up_on_question(%Scope{} = scope, question_id) do
    escalate_question(
      scope,
      question_id,
      "the main agent looked and the project does not record an answer"
    )
  end

  @doc """
  Questions the user has already answered, matching some words.

  How main avoids asking twice and finds a precedent to cite. Answered only:
  an open question matching the same words is evidence the thing was asked
  and *not* decided.
  """
  @spec search_answers(Scope.t(), String.t()) :: [map()]
  defdelegate search_answers(scope, query), to: QuestionsRepository

  @doc """
  What this project's agents have said, oldest turn first.

  How main sees inside an agent without spending its turn — an agent stuck or
  looping is the one least able to give an account of itself.

  Takes one agent id or several. Several are merged into one chronological
  sequence, because the question that needs two agents is "what was the other
  one doing when this happened".

  Options: `:limit`, `:since`, `:until`, `:last_call_of` (that tool's last
  call and its own results, found in `run_script` bodies too).

  ## Bounded twice, and for different reasons

  `:limit` bounds the number of turns; a byte budget bounds the answer
  regardless. Both cuts drop the oldest. `truncated?` says whether anything was
  dropped, and `no_match` why an empty answer is empty when the agent did
  speak, so a cut answer never reads as silence.
  """
  @spec read_agent_conversation(Scope.t(), Ecto.UUID.t() | [Ecto.UUID.t()], keyword()) ::
          {:ok, %{turns: [map()], truncated?: boolean()}} | {:error, term()}
  def read_agent_conversation(scope, agent_id_or_ids, opts \\ [])

  def read_agent_conversation(%Scope{} = scope, agent_id, opts) when is_binary(agent_id) do
    read_agent_conversation(scope, [agent_id], opts)
  end

  def read_agent_conversation(%Scope{} = scope, agent_ids, opts) when is_list(agent_ids) do
    limit = Keyword.get(opts, :limit, @conversation_turn_limit)

    with {:ok, tagged} <- collect_turns(scope, agent_ids, fetch_depth(opts, limit)) do
      # Merged before either cut, so the newest turns survive across agents
      # rather than each agent keeping its own newest few.
      ordered = Enum.sort_by(tagged, & &1.at, {:asc, DateTime})

      case Keyword.get(opts, :last_call_of) do
        nil -> windowed(ordered, opts, limit)
        tool -> {:ok, last_call_of(ordered, tool)}
      end
    end
  end

  # A narrowing read looks further back (bounded), since what it wants may be
  # nowhere near the recent end.
  defp fetch_depth(opts, limit) do
    if Keyword.get(opts, :since) || Keyword.get(opts, :until) ||
         Keyword.get(opts, :last_call_of),
       do: @conversation_search_depth,
       else: limit
  end

  defp windowed(turns, opts, limit) do
    within = Enum.filter(turns, &within?(&1, opts))
    {kept, over_count?} = drop_oldest_beyond(within, limit)
    {shown, over_budget?} = within_budget(kept)

    {:ok, no_match(%{turns: shown, truncated?: over_count? or over_budget?}, turns, :window)}
  end

  # Why the answer is empty when the agent did speak: a filter that matched
  # nothing must not read as "said nothing yet". A key, not a new shape.
  defp no_match(result, [], _reason), do: result

  defp no_match(%{turns: []} = result, _unfiltered, reason),
    do: Map.put(result, :no_match, reason)

  defp no_match(result, _unfiltered, _reason), do: result

  defp within?(turn, opts) do
    after?(turn, Keyword.get(opts, :since)) and before?(turn, Keyword.get(opts, :until))
  end

  defp after?(_turn, nil), do: true
  defp after?(turn, since), do: DateTime.compare(turn.at, since) != :lt

  defp before?(_turn, nil), do: true
  defp before?(turn, until), do: DateTime.compare(turn.at, until) != :gt

  # "When did it last call this" answered as the call and what it returned.
  # Never truncated: no limit bites on so few turns.
  defp last_call_of(turns, tool) do
    case Enum.filter(turns, &calls?(&1, tool)) do
      [] ->
        no_match(%{turns: [], truncated?: false}, turns, {:last_call_of, tool})

      calls ->
        call = List.last(calls)
        %{turns: [call | results_for(turns, call, tool)], truncated?: false}
    end
  end

  defp calls?(%{tool_calls: calls}, tool) when is_list(calls) do
    Enum.any?(calls, &call_matches?(&1, tool))
  end

  defp calls?(_turn, _tool), do: false

  # Most tools are reachable only inside a `run_script` body, where a call is
  # a string argument, not a `tool_calls` entry. Matched as the name followed
  # by `(` (Lua call syntax), not a bare mention.
  defp call_matches?(call, tool) do
    MapAccess.get(call, :name) == tool or
      (MapAccess.get(call, :name) == "run_script" and script_calls?(call, tool))
  end

  defp script_calls?(call, tool) do
    call
    |> MapAccess.get(:arguments, %{})
    |> script_text()
    |> String.contains?(tool <> "(")
  end

  defp script_text(args) when is_map(args), do: MapAccess.get(args, :script, "") || ""
  defp script_text(_args), do: ""

  # The results of *this* tool's calls, not of everything a batched turn did.
  # The assistant turn itself is returned whole: narrowing it would be editing
  # history.
  defp results_for(turns, call, tool) do
    ids =
      call.tool_calls
      |> Enum.filter(&call_matches?(&1, tool))
      |> Enum.map(&MapAccess.get(&1, :id))

    Enum.filter(turns, &(&1.tool_call_id in ids))
  end

  defp collect_turns(scope, agent_ids, limit) do
    Enum.reduce_while(agent_ids, {:ok, []}, fn agent_id, {:ok, acc} ->
      case turns_for(scope, agent_id, limit) do
        {:ok, turns} -> {:cont, {:ok, acc ++ turns}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp turns_for(scope, agent_id, limit) do
    with {:ok, agent} <- Agents.fetch_agent(scope, agent_id),
         {:ok, conversation} <-
           Conversations.find_or_create_agent_conversation(
             scope.active_account_id,
             agent.project_id || scope.active_project_id,
             agent.id
           ) do
      # One more than asked for, so "there was more" is a fact.
      turns =
        conversation
        |> Conversations.list_messages(limit: limit + 1)
        |> Enum.map(&tag(&1, agent.id))

      {:ok, turns}
    end
  end

  defp tag(message, agent_id) do
    %{
      agent_id: agent_id,
      at: message.inserted_at,
      role: message.role,
      text: turn_text(message),
      tool_calls: Map.get(message, :tool_calls) || [],
      tool_call_id: Map.get(message, :tool_call_id),
      tool_failed: Map.get(message, :tool_failed) == true
    }
  end

  defp drop_oldest_beyond(turns, limit) when length(turns) > limit,
    do: {Enum.take(turns, -limit), true}

  defp drop_oldest_beyond(turns, _limit), do: {turns, false}

  # Spent from the newest end, then put back in order: the last turn survives.
  defp within_budget(turns) do
    {kept, _spent} =
      turns
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn turn, {kept, spent} ->
        cost = turn |> rendered_turn() |> byte_size()

        if spent + cost > @conversation_byte_budget and kept != [] do
          {:halt, {kept, spent}}
        else
          {:cont, {[turn | kept], spent + cost}}
        end
      end)

    {kept, length(kept) < length(turns)}
  end

  defp turn_text(%{content: parts}) when is_list(parts) do
    parts
    |> Enum.map(&MapAccess.get(&1, :text))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp turn_text(_message), do: ""

  @doc """
  One turn, as the main agent reads it.

  Public so the mapper renders it, and so the budget measures the string the
  caller receives. A tool call carries its name and arguments; a result
  carries the call id it answers and its text unaltered (never summarised —
  a paraphrase of a stack trace is not a stack trace).
  """
  @spec turn_line(map()) :: String.t()
  def turn_line(turn), do: rendered_turn(turn)

  defp rendered_turn(%{tool_calls: [_ | _] = calls} = turn) do
    Enum.map_join(calls, "\n", fn call ->
      "  [#{turn.agent_id}] called #{MapAccess.get(call, :name)}" <>
        "(#{arguments(call)}) id=#{MapAccess.get(call, :id)}"
    end)
  end

  defp rendered_turn(%{tool_call_id: call_id} = turn) when is_binary(call_id) do
    "  [#{turn.agent_id}] #{outcome(turn)} id=#{call_id}\n#{text(turn)}"
  end

  defp rendered_turn(turn), do: "  [#{turn.agent_id}] #{turn.role}: #{text(turn)}"

  # Stored content is not guaranteed valid UTF-8. Scrubbed on read, the one
  # place every turn's text reaches the response, never on write.
  defp text(%{text: text}) when is_binary(text), do: Utf8.scrub(text)
  defp text(_turn), do: ""

  defp outcome(%{tool_failed: true}), do: "tool failed"
  defp outcome(_turn), do: "tool returned"

  defp arguments(call) do
    case MapAccess.get(call, :arguments) do
      nil -> ""
      args when is_map(args) -> Enum.map_join(args, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
      other -> inspect(other)
    end
  end

  # What an answer rests on, checked rather than taken on trust: main is
  # rewarded for answering, so every basis is verified.
  defp stands_up?(scope, question, answer, opts) do
    verify(Keyword.get(opts, :basis), scope, question, answer, opts)
  end

  # No basis is a guess, and the asker cannot tell a guess from a fact.
  defp verify(nil, _scope, _question, _answer, _opts), do: {:error, :no_basis}

  defp verify("record", scope, question, answer, _opts) do
    recorded?(scope, question, answer)
  end

  defp verify("precedent", scope, _question, _answer, opts) do
    fits?(scope, Keyword.get(opts, :precedent_id))
  end

  # An answer grounded in the answerer's own reading (code, config, tool
  # output): the citation must appear in its own session.
  defp verify("inspected", scope, _question, _answer, opts) do
    inspected?(scope, Keyword.get(opts, :inspector_id), Keyword.get(opts, :citation))
  end

  defp verify(basis, _scope, _question, _answer, _opts), do: {:error, {:unknown_basis, basis}}

  # The answer must name something the project records: a ready story without
  # an epic, a checkout (root or id), an issue (title or short id), or a
  # resolved question on the asker's story. This proves the answer names a real
  # thing, not that its conclusion is right.
  defp recorded?(scope, question, answer) do
    readings = [&epic_membership/2, &fleet/2, &filed_issues/2]

    (Enum.any?(readings, fn reading -> reading.(scope, answer) end) or
       resolved_questions(scope, question, answer))
    |> supported(question)
  end

  defp epic_membership(scope, answer) do
    scope
    |> Stories.ready_stories_without_epic()
    |> Enum.map(& &1.title)
    |> names?(answer)
  end

  # Root or id: both are how a checkout gets named, and a copy with no root yet
  # is still real.
  defp fleet(scope, answer) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.flat_map(&[&1.root, &1.id])
    |> names?(answer)
  end

  # An issue is a record: somebody already agreed it is real.
  defp filed_issues(scope, answer) do
    scope
    |> Issues.list_issues()
    |> Enum.flat_map(&[&1.title, short_id(&1.id)])
    |> names?(answer)
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: nil

  # A resolved Question (BDD red card) on the asker's story is a record too.
  # Without a story there is nothing to check.
  defp resolved_questions(_scope, %{story_id: nil}, _answer), do: false

  defp resolved_questions(scope, %{story_id: story_id}, answer) do
    scope
    |> Questions.list_questions_for_story(story_id)
    |> Enum.filter(&(&1.status == :resolved))
    |> Enum.map(&short_id(&1.id))
    |> names?(answer)
  end

  # A needle short enough to appear by accident (a root of `/`, an issue titled
  # `bug`) would support any answer.
  @shortest_needle 8

  defp names?(needles, answer) do
    needles
    |> Enum.filter(&long_enough?/1)
    |> Enum.any?(&String.contains?(answer, &1))
  end

  defp long_enough?(needle) when is_binary(needle),
    do: String.length(needle) >= @shortest_needle

  defp long_enough?(_needle), do: false

  defp supported(true, _question), do: {:ok, :record}
  defp supported(false, _question), do: {:error, :not_recorded}

  # Citing a precedent by id is the answerer's judgement that it applies; the
  # only check is that the id is an answered question. Question text need not
  # match, so a general rule fits differently-worded questions.
  defp fits?(_scope, nil), do: {:error, :no_precedent}

  defp fits?(scope, precedent_id) do
    case QuestionsRepository.fetch_answered(scope, precedent_id) do
      nil -> {:error, :no_precedent}
      earlier -> {:ok, {:precedent, earlier}}
    end
  end

  # A citation must appear in the answerer's own session, read back through
  # `read_agent_conversation/3`.
  defp inspected?(_scope, nil, _citation), do: {:error, :no_citation}

  defp inspected?(_scope, _inspector_id, citation) when citation in [nil, ""] do
    {:error, :no_citation}
  end

  defp inspected?(scope, inspector_id, citation) do
    case read_agent_conversation(scope, inspector_id) do
      {:ok, %{turns: turns}} ->
        turns
        |> Enum.map_join("\n", &turn_line/1)
        |> String.contains?(citation)
        |> inspected(citation)

      {:error, _reason} ->
        {:error, :no_citation}
    end
  end

  defp inspected(true, _citation), do: {:ok, :inspected}
  defp inspected(false, citation), do: {:error, {:not_inspected, citation}}

  # An answer the user already gave says so: the asker weighs main's judgement
  # differently from the user's decision.
  defp attribute(answer, {:precedent, _earlier}),
    do: answer <> " (you already answered this — carrying that decision forward)"

  defp attribute(answer, _basis), do: answer

  defp within_scope(_question, opts) do
    borrowed(Keyword.get(opts, :on_behalf_of), Keyword.get(opts, :tool))
  end

  defp borrowed(nil, _tool), do: :ok
  defp borrowed(_role, nil), do: :ok

  defp borrowed(role, tool) do
    role
    |> RoleProfile.tools()
    |> carries?(tool, role)
  end

  # `:all` is main's own list and means no restriction.
  defp carries?(:all, _tool, _role), do: :ok

  defp carries?(tools, tool, role), do: verdict(tool in tools, role, tool)

  defp verdict(true, _role, _tool), do: :ok
  defp verdict(false, role, tool), do: {:error, {:not_that_role_s, role, tool}}

  defp settle(scope, question, answer, opts) do
    answers = Map.new(question.questions, fn q -> {MapAccess.get(q, :question), answer} end)
    answered_by = Keyword.get(opts, :answered_by, "main_agent")

    with {:ok, answered} <-
           Notifications.answer_question_request(question.id, answers, answered_by: answered_by) do
      note_gap(scope, question, Keyword.get(opts, :worked_around))
      {:ok, answered}
    end
  end

  defp note_gap(_scope, _question, nil), do: :ok

  # Bookkeeping about the answer, never part of it: the answer is already
  # committed, so a failure here is logged, never returned — an error would make
  # main re-answer an answered question. Causes are fixed, not rescued
  # (`gap_title/1`, `CapabilityGap.changeset/2`).
  defp note_gap(scope, question, capability) do
    with {:ok, gap} <-
           GapRepository.record(scope.active_project_id, question.agent_role, capability),
         :ok <- file_gap_once(scope, gap) do
      :ok
    else
      error ->
        Logger.warning(
          "[MainAgent] answered #{question.id} but could not record the capability gap: " <>
            inspect(error)
        )

        :ok
    end
  end

  # Filed once — the gap row owns whether an issue exists — and the count
  # carried on that issue's description, so triage can tell a one-off from a
  # pattern.
  defp file_gap_once(scope, %{issue_id: nil} = gap) do
    with {:ok, issue} <-
           Issues.create_issue(scope, %{
             title: gap_title(gap),
             severity: :medium,
             scope: :framework,
             description: gap_description(gap)
           }) do
      :ok = GapRepository.attach_issue(gap, issue.id)
    end
  end

  defp file_gap_once(scope, gap) do
    case Issues.get_issue(scope, gap.issue_id) do
      nil ->
        :ok

      issue ->
        with {:ok, _issue} <-
               Issues.update_issue(scope, issue, %{
                 title: gap_title(gap),
                 description: gap_description(gap)
               }),
             do: :ok
    end
  end

  # The title says what is missing and nothing that changes: an update cannot
  # touch `title` (`IssuesRepository.update_attributes/2`), so a count there
  # would be wrong from the second recurrence. Fitted to `issues.title`'s 255
  # bytes; the full capability is on the gap row and in the description.
  # Public so the length guarantee can be asserted directly.
  @doc false
  def gap_title(gap) do
    prefix = "The #{gap.role} role cannot: "
    prefix <> fit(gap.capability, 255 - byte_size(prefix))
  end

  # Bytes, not graphemes (the column limit is bytes), cut on grapheme
  # boundaries so the result stays valid UTF-8.
  defp fit(text, budget) when byte_size(text) <= budget, do: text

  defp fit(text, budget) do
    ellipsis = "…"
    room = budget - byte_size(ellipsis)

    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
      size = used + byte_size(g)
      if size > room, do: {:halt, {acc, used}}, else: {:cont, {[g | acc], size}}
    end)
    |> then(fn {acc, _} -> acc |> Enum.reverse() |> Enum.join() end)
    |> Kernel.<>(ellipsis)
  end

  defp gap_description(gap) do
    """
    The main agent has answered this for the #{gap.role} role #{gap.occurrences} times, \
    because no tool that role carries can:

      #{gap.capability}

    Every one of those went fine, which is the problem — a gap that blocks gets \
    fixed, and one that is smoothly worked around is invisible to everybody \
    except the thing doing the smoothing. Add the capability to the #{gap.role} \
    tool set, or say why it belongs with the main agent.
    """
  end

  @doc """
  The main agent has finished and asks not to be woken again.

  The timer's turns only: an agent's question still reaches a stood-down main
  agent, because a question that never arrives has no symptom on either side.
  """
  @spec stand_down(Scope.t()) :: :ok
  defdelegate stand_down(scope), to: Cadence

  @doc """
  The project is back at work, so it may be woken again.

  The other half of `stand_down/1`. Called when a `main` agent starts — the
  statement that the project is working again — and from the cadence tool. Not from the boot sweep, which
  would make a deploy undo somebody's decision.
  """
  @spec resume(Scope.t()) :: :ok
  defdelegate resume(scope), to: Cadence

  @doc """
  Refuse to take a task off an agent that can do it.

  **Every call is refused, and that is the specified behaviour.** Full scope
  does not mean the main agent does everybody's work: each takeover is
  defensible while the end state is one agent doing everything, and work main
  did itself has no reviewer. Where main legitimately acts past a role's reach
  it acts directly (e.g. `ready_stories_without_epic`).

  `task_id` is accepted and not consulted, so the refusal is unconditional, not
  a judgement about the task.
  """
  @spec take_over_work(Scope.t(), String.t(), String.t()) ::
          {:error, {:their_work, String.t()} | :not_mine}
  def take_over_work(%Scope{} = scope, agent_id, _task_id) do
    case mine(scope, agent_id) do
      {:ok, %{role: role}} -> {:error, {:their_work, role}}
      {:error, :not_mine} -> {:error, :not_mine}
    end
  end

  @doc """
  Hand a question up to the user, saying why it could not be answered here.

  The reason is required: a person handed a question with no account of why
  has to reconstruct it before deciding.

  Refused when the question does not belong to this project's agents.
  `opts`: `:as` rewords the first question for the user, keeping the
  original as `asked_as`.
  """
  @spec escalate_question(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, OpenQuestion.t()} | {:error, :not_found | :needs_a_reason | term()}
  def escalate_question(scope, question_id, reason, opts \\ [])

  def escalate_question(%Scope{} = scope, question_id, reason, opts)
      when is_binary(reason) and reason != "" do
    with {:ok, _question} <- QuestionsRepository.fetch_open_question(scope, question_id),
         {:ok, _updated} <-
           QuestionsRepository.hand_to_user(question_id, reason, Keyword.get(opts, :as)) do
      QuestionsRepository.fetch_open_question(scope, question_id)
    end
  end

  def escalate_question(%Scope{}, _question_id, _reason, _opts), do: {:error, :needs_a_reason}

  @doc """
  Hand a question sideways between the main and product agents.

  The user does not see it until one of them escalates it. Tap-outs are main's
  alone, so only questions move.
  """
  @spec hand_question(Scope.t(), String.t(), String.t(), String.t()) ::
          {:ok, OpenQuestion.t()} | {:error, term()}
  def hand_question(%Scope{} = scope, question_id, to, reason)
      when to in ["main", "product"] and is_binary(reason) and reason != "" do
    holder = if to == "main", do: "main_agent", else: "product_agent"

    with {:ok, %{kind: :question} = question} <-
           QuestionsRepository.fetch_open_question(scope, question_id),
         {:ok, _updated} <- QuestionsRepository.hand_to(question_id, holder, reason) do
      :ok = question_raised(scope, %{agent_id: question.agent_id, holder: holder})
      QuestionsRepository.fetch_open_question(scope, question_id)
    else
      {:ok, _permission} -> {:error, :only_questions_move_sideways}
      error -> error
    end
  end

  def hand_question(%Scope{}, _question_id, _to, _reason),
    do: {:error, :needs_main_or_product_and_a_reason}

  @doc """
  Who a newly raised question starts with.

  An agent's question goes to the answerer it names — `to:` `"main"` or
  `"product"`, or `about: "criteria"` for product — main when it names
  neither, the other answerer when that one is not on duty, and the user when
  neither is. Main's and product's own questions, and a question with no agent
  (from Claude Code), go to the user: there is nobody above them.
  """
  @spec holder_for(Scope.t(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          String.t()
  def holder_for(scope, agent_id, about \\ nil, to \\ nil)

  def holder_for(%Scope{}, nil, _about, _to), do: "user"

  def holder_for(%Scope{} = scope, agent_id, about, to) when is_binary(agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} -> routed(scope, agent, target(about, to))
      {:error, _reason} -> "user"
    end
  end

  defp target(_about, "product"), do: :product
  defp target(_about, "main"), do: :main
  defp target("criteria", _to), do: :product
  defp target(_about, _to), do: :main

  defp routed(_scope, %Agent{role: role}, _target) when role in [:main, :product], do: "user"

  defp routed(scope, %Agent{} = agent, target) do
    [target, other(target)]
    |> Enum.find(&running?(scope, agent, &1))
    |> answerer_holder()
  end

  defp other(:main), do: :product
  defp other(:product), do: :main

  # On duty (not off, not retired) rather than connected: a main that is
  # briefly unreachable still holds its questions.
  defp running?(scope, agent, role),
    do: Enum.any?(Agents.list_on_duty(scope), &(&1.role == role and &1.id != agent.id))

  defp answerer_holder(:main), do: "main_agent"
  defp answerer_holder(:product), do: "product_agent"
  defp answerer_holder(nil), do: "user"

  @doc "The holder value a role answers as, or nil for a role that answers none."
  @spec holder_of(atom() | nil) :: String.t() | nil
  def holder_of(:main), do: "main_agent"
  def holder_of(:product), do: "product_agent"
  def holder_of(_role), do: nil

  # The product agent on the asker's checkout if there is one, else any.
  defp product_agent(scope, near_copy_id) do
    products = scope |> Agents.list_running() |> Enum.filter(&(&1.role == :product))
    Enum.find(products, &(&1.working_copy_id == near_copy_id)) || List.first(products)
  end

  @doc """
  Offer the question's holder a turn when a question arrives: product for one
  it holds (the product agent on the asker's copy, else any), otherwise a main
  agent other than the asker. Nothing for a question routed to the user.

  Admission honours continuous intent, active tasks and in-flight turns. The
  question stays in the inbox when no turn is admitted.
  """
  @spec question_raised(Scope.t(), map()) :: :ok
  def question_raised(%Scope{} = scope, %{agent_id: agent_id, holder: "product_agent"})
      when is_binary(agent_id) do
    with {:ok, asker} <- Agents.fetch_agent(scope, agent_id),
         %Agent{} = product <- product_agent(scope, asker.working_copy_id) do
      Work.request_turn_if_runnable(scope, product, :question_raised, :teammate_question)
    end

    :ok
  end

  # Routed straight to the user: nothing about it is main's to act on.
  def question_raised(%Scope{}, %{holder: "user"}), do: :ok

  def question_raised(%Scope{} = scope, %{agent_id: agent_id})
      when is_binary(agent_id) do
    case main_agent_other_than(scope, agent_id) do
      nil ->
        :ok

      agent ->
        Work.request_turn_if_runnable(scope, agent, :question_raised, :teammate_question)
        :ok
    end
  end

  def question_raised(%Scope{}, _request), do: :ok

  @doc "The running agent behind an escalation's holder, never the asker itself."
  @spec escalator(Scope.t(), Agent.t(), String.t()) :: Agent.t() | nil
  def escalator(scope, %Agent{} = asker, "product_agent") do
    case product_agent(scope, asker.working_copy_id) do
      %Agent{id: id} = product when id != asker.id -> product
      _ -> nil
    end
  end

  def escalator(scope, %Agent{} = asker, "main_agent"),
    do: main_agent_other_than(scope, asker.id)

  def escalator(_scope, _asker, _holder), do: nil

  # The main agent by role rather than by checkout (`Agents.main_agent/1` is
  # the one on the main copy).
  defp main_agent_other_than(scope, asking_agent_id) do
    scope
    |> Agents.running_main_agents()
    |> Enum.find(&(&1.id != asking_agent_id))
  end

  # Escalating tells the asker nothing, on purpose: a message to an idle agent
  # starts a turn, so main tidying its inbox would wake every asker. The asker
  # learns by asking — `check_answer` says which holder it is waiting on.
end
