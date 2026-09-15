defmodule CodeMySpec.MainAgent do
  @moduledoc """
  The agent that owns a project, and the view across everything working in it.

  `CodeMySpec.Agents` owns an agent — start it, stop it, deliver it a message.
  This owns the judgement *about* them: what every agent in every checkout is
  waiting on, which of it the main agent can settle itself, and which of it is
  worth a person's attention. One is a lifecycle, the other is a position, and
  the position is a project's rather than a checkout's.

  ## A question has a holder

  Story 1053's finding, and the shape everything here rests on. `status` says
  whether a question is finished; it cannot say who it is finished *by*, and
  the two readers of an open question want opposite things from that word. The
  main agent wants what still needs it. The person wants what reached them.

  So an agent's question starts held by the main agent, and escalating moves
  the holder rather than closing the question. The two alternatives are the two
  failures criterion 3264 names: deleted, the main agent sees its own
  escalations forever and cannot tell the handled from the unhandled; answered,
  the person's question vanishes from under them while they are reading it.

  ## What it does not do

  Answering is story 1060 and is deliberately not here yet. The main agent can
  see what is waiting and pass up what is the user's call; deciding what it can
  settle from the project's own records is the next story, and building half of
  it here would put the judgement in two places.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents,
      CodeMySpec.Analysis,
      CodeMySpec.Configurations,
      CodeMySpec.Conversations,
      CodeMySpec.Devices,
      CodeMySpec.Faults,
      CodeMySpec.Issues,
      CodeMySpec.Notifications,
      CodeMySpec.Problems,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.Utils,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.Conversations
  alias CodeMySpec.Issues
  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.Cadence
  alias CodeMySpec.MainAgent.CheckInReport
  alias CodeMySpec.MainAgent.Digest
  alias CodeMySpec.MainAgent.GapRepository
  alias CodeMySpec.MainAgent.Machinery
  alias CodeMySpec.MainAgent.MachineryRepository
  alias CodeMySpec.MainAgent.OpenQuestion
  alias CodeMySpec.MainAgent.QuestionsRepository
  alias CodeMySpec.MainAgent.RestartRepository
  alias CodeMySpec.MainAgent.WorkRepository
  alias CodeMySpec.Notifications
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.WorkingCopies

  @doc """
  Everything this project's agents are waiting on, wherever they are running.

  Oldest first, answered ones gone. Criterion 3262: a list that only grows is a
  list nobody reads, and every answered question left in it makes the next real
  one harder to see.
  """
  @spec list_open_questions(Scope.t()) :: [OpenQuestion.t()]
  defdelegate list_open_questions(scope), to: QuestionsRepository

  @doc """
  What every running agent on this project is doing, across all its checkouts.

  Parts rather than a verdict, which is criterion 3275 and the constraint the
  whole view is built around: the caller decides what a silence means, because
  the rules that would decide it here are wrong in exactly the cases that
  matter.
  """
  @spec list_agent_work(Scope.t()) :: [AgentWork.t()]
  def list_agent_work(%Scope{} = scope) do
    work = WorkRepository.list_agent_work(scope)
    :ok = review_restarts(scope, work)
    work
  end

  # Looking is when a failed remedy is noticed, because nothing else looks.
  #
  # Criterion 3308's words are "when the main agent *sees* that the restart
  # changed nothing" — not when it tries again. Waiting for the next attempt is
  # what turns a fault into a state to be managed: the agent stays broken and
  # the only thing that would report it is the thing the report is supposed to
  # prevent.
  #
  # A write during a read, deliberately and with precedent — `actionable_count`
  # settles the graph the same way. Settling is idempotent and the issue is
  # raised once per agent and reason, so a main agent that checks every twenty
  # minutes does not file the same fault seventy times a day.
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

  The answer to "is it the agent or is it the machine", which is the question
  the main agent actually has when something is wrong — and the one it could
  not ask before, so it answered it by restarting things until something
  changed.
  """
  @spec check_machinery(Scope.t()) :: Machinery.t()
  def check_machinery(%Scope{} = scope) do
    machinery = MachineryRepository.check(scope)
    :ok = report_machinery_fault(scope, machinery)
    machinery
  end

  # Looking is when a machinery fault is raised, because nothing else looks.
  #
  # Criterion 3312's words are "when the main agent *finds* it, then it raises
  # the fault" — finding is the act. The alternative is raising it when somebody
  # next tries to restart something, which means a fault nobody happens to trip
  # over goes unrecorded, and this is precisely the class of fault that went
  # unseen for four hours.
  #
  # Only the machine-wide case. A fault belonging to one agent is that agent's
  # and is within reach — criterion 3321 — so filing it would be the "raise
  # everything and fix nothing" failure that criterion exists to prevent.
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

  The reason is required and is the whole mechanism. A main agent restarts on
  its own judgement, far more often than a person would, and the thing a person
  supplied by eventually getting bored has to come from the record: what has
  already been tried for this, and whether it worked.

  ## The three answers

  `{:ok, agent}` — restarted, recorded with its reason on the agent's own
  thread so a reader sees it in sequence with the work it interrupted.

  `{:error, :not_mine}` — the id does not name an agent of this project. That
  covers the case criterion 3307 is about: a main agent reaching for the harness
  because restarting it would clear the fault. It would, and it would also kill
  in-flight work on every checkout on the machine including other projects', so
  the fault is raised for somebody who can weigh that instead.

  `{:error, {:already_tried, n}}` — this reason has been tried `n` times and the
  agent has not been seen working since any of them. Refused and raised, because
  a refusal that tells nobody leaves an agent broken with not even a loop to
  notice it.

  A restart whose predecessor did not work is allowed and raised: one failed
  remedy is already evidence that restarting is the wrong one, and waiting for
  the third to say so costs two more turns.
  """
  @spec restart_agent(Scope.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error,
             :not_mine | :needs_a_reason | :machinery_faulty | {:already_tried, pos_integer()}}
  def restart_agent(%Scope{} = scope, agent_id, reason)
      when is_binary(reason) and reason != "" do
    case mine(scope, agent_id) do
      {:ok, agent} ->
        :ok = RestartRepository.settle(agent)
        consider(scope, agent, reason)

      {:error, :not_mine} ->
        out_of_reach(scope, agent_id, reason)
    end
  end

  # Grouped with the clause above rather than sitting after the private
  # functions it used to follow: separated clauses of one function are a
  # compiler warning, and the warning is right — a reader who finds this one
  # first sees a `restart_agent/3` that refuses everything.
  def restart_agent(%Scope{}, _agent_id, _reason), do: {:error, :needs_a_reason}

  # A fault underneath the agent is not one a restart reaches.
  #
  # Criterion 3312, and it fires on the first attempt rather than the fourth.
  # 3292 and 3308 are about noticing after several that restarting is not
  # working — a count of failed remedies. This is about not starting: the
  # machinery being faulty is known *before* the first restart, from the same
  # report the main agent just read, and acting anyway is a mistake that report
  # already carried the information to prevent.
  #
  # The agent comes back into the same dead client, so the attempt costs a turn
  # and changes nothing — and the main agent cannot learn that from the outcome,
  # because an agent that came back broken looks exactly like one that is slow
  # to recover.
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

  # How much of an agent's conversation one read hands back.
  #
  # Two bounds rather than one: turns are not a uniform size, so a count alone
  # does not bound the answer - a single tool result can outweigh fifty ordinary
  # turns. The byte budget is what protects the caller's context; the turn count
  # is what makes the common "what has it been doing" read small.
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
      # Told to the agent, not written past it. A restarted agent has lost the
      # turn it was in the middle of; why that happened is the one thing it
      # cannot work out for itself, and an orchestrator row saying so was
      # dropped from its context before it ever got there.
      Agents.send_to_agent(restarted.id, "Restarted: #{reason}")

      {:ok, restarted}
    end
  end

  # Refusing and telling nobody is the failure criterion 3307 actually names.
  #
  # The point of not taking an action you must not take is to convert it into a
  # decision for somebody who can. A refusal that ends there is worse than the
  # action, because at least the action would have been noticed — and what the
  # main agent was reaching for here is a harness restart, which would have
  # killed in-flight work on every checkout on that machine.
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

  # An agent of this project, and nothing else.
  #
  # `Agents.fetch_agent/2` is already project-scoped, so a working copy id, a
  # harness id or another project's agent all land here the same way — which is
  # the answer criterion 3307 wants for every one of them.
  defp mine(scope, agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} -> {:ok, agent}
      {:error, _reason} -> {:error, :not_mine}
    end
  end

  # Raised where a person looks at a particular project, rather than in a log.
  #
  # This is precisely the class of fault that was invisible for four hours: an
  # agent that could not work, a remedy that did not reach it, and nothing
  # anywhere saying so.
  # The reason belongs in the title, not only the body.
  #
  # `list_issues` shows titles. An issue list where every entry reads "A restart
  # changed nothing" is unreadable at exactly the moment somebody is scanning it
  # for which agent is stuck — and the fault is the only part that differs.
  defp titled(what, reason), do: "#{what}: #{String.slice(reason, 0, 120)}"

  # Once per fault, not once per call that notices it.
  #
  # A fault these raise — the machinery serving no tools, a restart that changed
  # nothing — lasts until a person deals with it, and the cadence keeps calling
  # `check_machinery` and `restart_agent` in the meantime. Every one of those
  # calls used to file another copy: two from a single `check_machinery`
  # followed by one `restart_agent`, and six identical issues from one QA
  # measurement. That buries the first, real issue under repeats of itself at
  # exactly the moment somebody is scanning the list for what is wrong — which
  # defeats criterion 3312, the thing this path exists to satisfy (`57ba014e`).
  #
  # Keyed on the title, which is what `titled/2` already builds from the fault
  # itself, so two different faults still file separately and the same fault
  # does not.
  #
  # Open only. A dismissed or resolved issue is finished with, so the same fault
  # recurring after that is news rather than a repeat.
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

  The check-in, and the thing that makes this story's cadence worth having: it
  carries the digest rather than an instruction to go and assemble one, so the
  wake-up is an answer instead of a turn spent getting to one.

  Quiet check-ins reach the main agent and nobody else — criterion 3320. A
  person hearing from this seventy-two times a day turns it off, and turning it
  off removes the one mechanism that catches an agent too broken to report.

  Silent when the main agent has stood down (3334) and when there is no main
  agent to wake, which is ordinary rather than an error.
  """
  @spec check_in(Scope.t()) :: :ok
  def check_in(%Scope{} = scope), do: wake(Cadence.running?(scope), scope)

  defp wake(false, _scope), do: :ok
  defp wake(true, scope), do: deliver_check_in(scope, Cadence.digest(scope))

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

  @doc "Start this project's cadence if it is not already running."
  @spec ensure_cadence(Scope.t()) :: {:ok, pid()} | {:error, term()}
  defdelegate ensure_cadence(scope), to: Cadence, as: :ensure_running

  @doc """
  Re-establish cadences for every project with agents running in it.

  The application's boot seeding calls this. Exposed on the context rather than
  reached into, because `Cadence` is inside this boundary and the web app is
  outside it — the compiler said so, which is the boundary doing its job.
  """
  @spec wake_active_projects() :: :ok
  defdelegate wake_active_projects, to: Cadence

  defp deliver_check_in(scope, %Digest{failed: reason} = digest) when is_binary(reason) do
    # Not delivered as an empty all-quiet, and raised. Criterion 3333: those are
    # opposite answers, and the empty one is the reassuring half — it says what
    # a healthy fleet says, for as long as whatever broke stays broken.
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

    tell_main_agent(scope, "The check-in could not be assembled: #{reason}")

    _ = digest
    :ok
  end

  defp deliver_check_in(scope, %Digest{} = digest) do
    tell_main_agent(scope, CheckInReport.render(digest))
  end

  # The report reaches the main agent as a message, the way everything else
  # that has something to say to an agent does. It used to be written into the
  # conversation as an orchestrator row, which `Chat.Runner.to_provider_message/1`
  # drops on the floor — so the check-in the main agent was meant to act on was
  # visible to the person watching and to nobody else.
  defp tell_main_agent(scope, text) do
    case main_agent_other_than(scope, nil) do
      nil ->
        :ok

      agent ->
        Agents.send_to_agent(agent.id, text)
        :ok
    end
  end

  @doc """
  Answer one of this project's open questions from what the project records.

  Story 1058's point: the main agent's wider reach is for *using*. A main agent
  that can see everything and answer nothing has replaced a person's inbox with
  its own — the agent waits exactly as long as before, with one more hop in the
  way.

  ## Refused when it would be a way round a role's own limits

  `on_behalf_of` and `tool` name a request to act as somebody else. Every
  scoping decision in `ToolSets` is advisory the moment that works: an agent
  that wants a tool it does not carry asks the main agent to use it, and the
  rule is gone with nothing recording that it was circumvented.

  The request is indistinguishable from a legitimate one by its shape — the
  difference is whether the role's not having the tool was a decision or an
  oversight — so the answer is the tool list itself. A role that does not carry
  it does not get it used on its behalf.

  ## `worked_around` is how a gap gets counted

  Whether an answer was a workaround or ordinary knowledge is a judgement only
  the thing that made it holds; inferring it from the question's prose would be
  guessing at intent. So the main agent says, and the counting is ours.
  """
  @spec answer_question(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def answer_question(%Scope{} = scope, question_id, answer, opts \\ []) do
    with {:ok, question} <- QuestionsRepository.fetch_open_question(scope, question_id) do
      case within_scope(question, opts) do
        :ok -> weigh(scope, question, answer, opts)
        refusal -> refusal
      end
    end
  end

  # An answer that does not stand up sends the question on rather than stopping
  # here.
  #
  # Criteria 3252, 3254 and 3258 each end "and the question reaches the user",
  # and a refusal that left it with the main agent would satisfy the first half
  # of all three while producing 3259's failure: an absorbed question, with no
  # symptom on any surface.
  #
  # The error still comes back. The main agent asked to answer and did not, and
  # telling it "done" would leave it believing the agent is unblocked.
  defp weigh(scope, question, answer, opts) do
    case stands_up?(scope, question, answer, opts) do
      {:ok, basis} ->
        settle(scope, question, attribute(answer, basis), opts)

      {:error, reason} ->
        {:ok, _escalated} = escalate_question(scope, question.id, why(reason))
        {:error, reason}
    end
  end

  defp why(:no_basis),
    do: "the main agent had nothing to base an answer on, so this is yours to decide"

  defp why(:not_recorded),
    do: "the project does not record an answer to this, so it is yours to decide"

  defp why(:precedent_does_not_fit),
    do:
      "this resembles something you decided before, and differs in a way that could " <>
        "change the answer — so it is yours rather than ours to carry forward"

  defp why(:no_precedent),
    do: "no earlier decision of yours covers this"

  defp why(reason), do: "the main agent could not answer this: #{inspect(reason)}"

  @doc """
  The main agent gives up on a question it could not answer.

  Criterion 3259, and the act that makes "go and find out" safe to ask for.
  Without it a question the main agent took and could not settle stays with it,
  and an absorbed question has no symptom on any surface: the inbox is quiet,
  the agent is quiet, and the project looks like one where nobody needs
  anything.

  Escalation with the trying written into the reason, so the person reading it
  knows the easy answers have been tried.
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

  Criterion 3256, and three criteria rest on it: without this reading the main
  agent cannot avoid asking twice, cannot recognise a precedent, and cannot tell
  a fitting one from a stretched one.

  Answered only. A precedent is by definition settled, and an open question
  matching the same words is the opposite — evidence that this has been asked
  and *not* decided, which would answer a new question from a question.
  """
  @spec search_answers(Scope.t(), String.t()) :: [map()]
  defdelegate search_answers(scope, query), to: QuestionsRepository

  @doc """
  What this project's agents have said, oldest turn first.

  Story 1013. The main agent supervises agents it cannot see inside, and the
  only way to learn what one had done was to send it a message and wait — which
  spends the agent's turn answering instead of working, and fails exactly when
  it is needed, because an agent that is stuck or looping is the one least able
  to give an account of itself.

  Takes one agent id or several. Several are merged into one chronological
  sequence rather than concatenated, because the question that needs two agents
  is "what was the other one doing when this happened", and two transcripts end
  to end do not answer it.

  ## Bounded twice, and for different reasons

  `:limit` bounds the number of turns, because a caller asking "what has it been
  doing" wants the recent end and not a transcript to page through.

  The byte budget bounds the answer regardless, because turns are not a uniform
  size — one tool result can outweigh fifty ordinary turns, so a count alone
  bounds nothing. Both cuts drop the oldest and keep the newest, which is the
  end that says what the agent is doing now.

  `truncated?` says whether anything was dropped. A read that silently returned
  part of a conversation is worse than one that refused: the caller cannot tell
  a quiet agent from a cut answer, and would read turns it never saw as silence.
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

  # A narrowing read has to look further back than a plain one, because the
  # turns it wants may be nowhere near the recent end — a window covering an
  # incident two days ago is not answered by the last fifty turns. Bounded
  # rather than unbounded: this is still a read into a caller's context.
  defp fetch_depth(opts, limit) do
    if Keyword.get(opts, :since) || Keyword.get(opts, :until) ||
         Keyword.get(opts, :last_call_of),
       do: @conversation_search_depth,
       else: limit
  end

  defp windowed(turns, opts, limit) do
    turns = Enum.filter(turns, &within?(&1, opts))
    {kept, over_count?} = drop_oldest_beyond(turns, limit)
    {shown, over_budget?} = within_budget(kept)

    {:ok, %{turns: shown, truncated?: over_count? or over_budget?}}
  end

  defp within?(turn, opts) do
    after?(turn, Keyword.get(opts, :since)) and before?(turn, Keyword.get(opts, :until))
  end

  defp after?(_turn, nil), do: true
  defp after?(turn, since), do: DateTime.compare(turn.at, since) != :lt

  defp before?(_turn, nil), do: true
  defp before?(turn, until), do: DateTime.compare(turn.at, until) != :gt

  # "When did it last call this" answered as the call and what it returned,
  # rather than by handing back the transcript to search. Criterion 3282: a
  # targeted question deserves a targeted answer, and a conversation long enough
  # to be worth asking about is one the caller cannot afford to read.
  #
  # Never truncated. Two turns are two turns, and reporting a cut here would be
  # describing a limit that did not bite.
  defp last_call_of(turns, tool) do
    case Enum.filter(turns, &calls?(&1, tool)) do
      [] ->
        %{turns: [], truncated?: false}

      calls ->
        call = List.last(calls)
        %{turns: [call | results_for(turns, call)], truncated?: false}
    end
  end

  defp calls?(%{tool_calls: calls}, tool) when is_list(calls) do
    Enum.any?(calls, &(MapAccess.get(&1, :name) == tool))
  end

  defp calls?(_turn, _tool), do: false

  defp results_for(turns, call) do
    ids = Enum.map(call.tool_calls, &MapAccess.get(&1, :id))
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
      # One more than asked for, so "there was more" is a fact about the
      # conversation rather than an inference from having filled the page.
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

  # Newest first while spending the budget, then put back in order. Measured
  # from the end rather than the front, because the turn that has to survive a
  # cut is the last one.
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

  Public so the mapper renders without reaching into a `Message`, and so the
  budget above measures the same string the caller will actually receive rather
  than an approximation of it.

  A tool call carries its name and arguments; a result carries the call id it
  answers and its text unaltered. Criterion 3281 is why the text is never
  summarised — a paraphrase of a stack trace is not a stack trace — and 3284 is
  why the call id is always shown: two identical results are two events, and a
  reader has to be able to see that rather than infer it.
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
    "  [#{turn.agent_id}] #{outcome(turn)} id=#{call_id}\n#{turn.text}"
  end

  defp rendered_turn(turn), do: "  [#{turn.agent_id}] #{turn.role}: #{turn.text}"

  defp outcome(%{tool_failed: true}), do: "tool failed"
  defp outcome(_turn), do: "tool returned"

  defp arguments(call) do
    case MapAccess.get(call, :arguments) do
      nil -> ""
      args when is_map(args) -> Enum.map_join(args, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
      other -> inspect(other)
    end
  end

  # What an answer rests on, checked rather than taken on trust.
  #
  # The pressure runs one way. A main agent told to spare the user is rewarded
  # for answering, and a rule that depends on the thing under pressure choosing
  # to follow it is not a rule — so `record` is verified against the record and
  # `precedent` against the earlier question.
  defp stands_up?(scope, question, answer, opts) do
    verify(Keyword.get(opts, :basis), scope, question, answer, opts)
  end

  # No basis is a guess, and a guess is the most expensive thing this can
  # produce: the asking agent cannot tell one from a looked-up fact, so it
  # proceeds on it and the error compounds while the user's question is never
  # asked.
  defp verify(nil, _scope, _question, _answer, _opts), do: {:error, :no_basis}

  defp verify("record", scope, question, answer, _opts) do
    recorded?(scope, question, answer)
  end

  defp verify("precedent", scope, question, _answer, opts) do
    fits?(scope, question, Keyword.get(opts, :precedent_id))
  end

  defp verify(basis, _scope, _question, _answer, _opts), do: {:error, {:unknown_basis, basis}}

  # The project has to actually contain the answer.
  #
  # A basis of `record` is a claim about the project, and a claim about the
  # project is checkable. Each reading is one thing the main agent can read;
  # an answer that names something in any of them is supported, and one that
  # names nothing in any of them is a guess, which is the right default.
  #
  # `24823f81` is why this is a list rather than a single call. It checked epic
  # membership alone — the one reading the criteria exercised — so a correct,
  # evidence-backed answer was refused as a guess whenever its evidence was
  # anything else. The fleet and the issues are the two the main agent actually
  # answers this class of question from, and both were unsupported.
  #
  # What this proves is that the answer names a real thing, not that it draws
  # the right conclusion from it. That is the honest limit, and it is the same
  # limit the single reading had: the check keeps out answers with nothing
  # behind them, and 3220 and 3222 exist because a cited record can still be
  # the wrong one.
  defp recorded?(scope, question, answer) do
    [&epic_membership/2, &fleet/2, &filed_issues/2]
    |> Enum.any?(fn reading -> reading.(scope, answer) end)
    |> supported(question)
  end

  defp epic_membership(scope, answer) do
    scope
    |> Stories.ready_stories_without_epic()
    |> Enum.map(& &1.title)
    |> names?(answer)
  end

  # `list_working_copies`, `list_agents` and `list_agent_work` are already how
  # the main agent answers "which checkout is this on" — the reading existed
  # everywhere except in the check that decides whether it counts.
  #
  # Root *or* id, because both are how a checkout gets named and the main agent
  # does not choose which it is handed. `list_open_questions` renders
  # `checkout: <id> <root>` and drops the root when there is none — a copy that
  # has never reported one is still a real copy, and an answer naming it by id
  # is grounded in exactly the same reading.
  defp fleet(scope, answer) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.flat_map(&[&1.root, &1.id])
    |> names?(answer)
  end

  # An accepted issue is about as recorded as an answer gets: it has a body, a
  # status, and somebody already agreed it is real. 24823f81 left this open and
  # the live case that reopened it was an answer whose whole content was "this
  # is issue f9cdb0b0, and here is its mechanism".
  defp filed_issues(scope, answer) do
    scope
    |> Issues.list_issues()
    |> Enum.flat_map(&[&1.title, short_id(&1.id)])
    |> names?(answer)
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: nil

  # A needle short enough to appear by accident makes every answer recorded,
  # which is the failure the basis exists to prevent. A copy rooted at `/`, or
  # an issue titled `bug`, would support anything at all.
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

  # A precedent is the same question, not a similar one.
  #
  # 3258's whole subject. A search returns similar text by construction, so the
  # claim has to be checked — and "same" is the question's own text, because any
  # looser rule is the stretching the criterion forbids.
  defp fits?(_scope, _question, nil), do: {:error, :no_precedent}

  defp fits?(scope, question, precedent_id) do
    scope
    |> QuestionsRepository.fetch_answered(precedent_id)
    |> same_question?(question)
  end

  defp same_question?(nil, _question), do: {:error, :no_precedent}

  defp same_question?(earlier, question) do
    matched(texts(earlier) == texts(question), earlier)
  end

  defp matched(false, _earlier), do: {:error, :precedent_does_not_fit}
  defp matched(true, earlier), do: {:ok, {:precedent, earlier}}

  defp texts(%{questions: questions}) do
    Enum.map(questions, fn question -> MapAccess.get(question, :question) end)
  end

  # An answer the user already gave says so.
  #
  # Criterion 3257's middle clause, and not decoration: an answer presented as
  # the main agent's own is one the agent weighs as a judgement, and the same
  # words attributed to a decision the user made are a fact.
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
    |> role_tools()
    |> carries?(tool, role)
  end

  defp role_tools(role) when is_binary(role) do
    ToolSets.for_role(String.to_existing_atom(role))
  rescue
    ArgumentError -> []
  end

  defp role_tools(role), do: ToolSets.for_role(role)

  # `nil` is main's own list and means no restriction; it never reaches here,
  # because a main agent asking itself for a favour is not a role escaping
  # anything.
  defp carries?(nil, _tool, _role), do: :ok

  defp carries?(tools, tool, role), do: verdict(tool in tools, role, tool)

  defp verdict(true, _role, _tool), do: :ok
  defp verdict(false, role, tool), do: {:error, {:not_that_role_s, role, tool}}

  defp settle(scope, question, answer, opts) do
    answers = Map.new(question.questions, fn q -> {MapAccess.get(q, :question), answer} end)

    with {:ok, answered} <-
           Notifications.answer_question_request(question.id, answers, answered_by: "main_agent") do
      note_gap(scope, question, Keyword.get(opts, :worked_around))
      {:ok, answered}
    end
  end

  defp note_gap(_scope, _question, nil), do: :ok

  defp note_gap(scope, question, capability) do
    with {:ok, gap} <-
           GapRepository.record(scope.active_project_id, question.agent_role, capability) do
      file_gap_once(scope, gap)
    end
  end

  # Filed once, and the count carried on the issue that exists.
  #
  # Criterion 3330's two halves are one decision here: the row owns whether an
  # issue exists, so "do not file a second" is a property of the data rather
  # than of whoever remembers to check — and the repeats are on the issue
  # instead of being dropped, which is what leaves triage able to tell a
  # one-off from the tip of something.
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
        Issues.update_issue(scope, issue, %{
          title: gap_title(gap),
          description: gap_description(gap)
        })
    end
  end

  # The title says what is missing and nothing that changes.
  #
  # The count would read better here — `list_issues` shows titles — and it
  # cannot live here: `update_attributes/2` whitelists the fields an update may
  # touch and `title` is not among them, deliberately, so a count written at
  # filing time would say "1" forever. A number that is wrong from the second
  # recurrence onwards is worse than one that needs `get_issue` to read.
  defp gap_title(gap), do: "The #{gap.role} role cannot: #{gap.capability}"

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

  The timer only. Criterion 3335: an agent's question still reaches a
  stood-down main agent, because the alternative has no symptom on either side
  — it is not woken, which is what it asked for, and the question never
  arrives.
  """
  @spec stand_down(Scope.t()) :: :ok
  defdelegate stand_down(scope), to: Cadence

  @doc """
  The project is back at work, so it may be woken again.

  The other half of `stand_down/1`, and until `5f9fad45` it had no caller at
  all — so a tap-out stood a project down permanently. Starting continuous work
  again began a fresh timer, and every tick of it no-oped, because the delivery
  gate still found the project in the stood-down list and nothing ever removed
  it. A cadence that ticks and never delivers is indistinguishable from a
  project nobody works on, which is the exact state story 1059 exists to make
  impossible.

  Called where somebody says the project is working again — a `main` agent
  starting. Not from the boot sweep, which would make a deploy silently undo a
  decision somebody made.
  """
  @spec resume(Scope.t()) :: :ok
  defdelegate resume(scope), to: Cadence

  @doc """
  Refuse to take a task off an agent that can do it.

  **Every call is refused today, and that is the specified behaviour.** The name
  reads like a capability and it is a boundary: criterion 3328 asserts that full
  scope does not mean the main agent does everybody's work, and nothing anywhere
  specifies when a takeover should instead succeed.

  Why refusing is the whole of it. The main agent may do anything, so watching an
  agent work slowly on something it could finish itself is a standing temptation
  — and each individual takeover is defensible while the end state is one agent
  doing everything with three idle, decided by nobody. It also removes what the
  roles are for: a coding agent's work is reviewed by QA because it is a coding
  agent's, and work the main agent did itself has no counterpart to check it.

  Where the main agent legitimately acts past a role's reach, it acts directly —
  criterion 3327, and `ready_stories_without_epic` is the worked example. That
  is a different act from confiscating an agent's task, and it already works.

  `task_id` is accepted and unused. It is kept because a caller naturally has one
  and dropping it from the signature would be a breaking change for nothing —
  but it is not consulted, so the refusal is unconditional rather than a
  judgement about the task's state. QA found that worth recording (3b7023ae):
  the refusal message reads like an assessment and is not one.

  If a real takeover is ever wanted, it needs a criterion saying when — and then
  `task_id` becomes load-bearing.
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

  The reason is required rather than optional. A question that arrives at a
  person with no account of why it reached them is one they have to reconstruct
  before they can decide, and reconstructing it is the work the main agent was
  supposed to have already done.

  Refused when the question does not belong to this project's agents: the main
  agent owns one project, and a reach that quietly extends past it is one
  nobody would notice had extended.
  """
  @spec escalate_question(Scope.t(), String.t(), String.t(), keyword()) ::
          {:ok, OpenQuestion.t()} | {:error, :not_found | :needs_a_reason | term()}
  def escalate_question(scope, question_id, reason, opts \\ [])

  def escalate_question(%Scope{} = scope, question_id, reason, opts)
      when is_binary(reason) and reason != "" do
    with {:ok, question} <- QuestionsRepository.fetch_open_question(scope, question_id),
         {:ok, _updated} <-
           QuestionsRepository.hand_to_user(question_id, reason, Keyword.get(opts, :as)) do
      QuestionsRepository.fetch_open_question(scope, question_id)
      |> tell_the_asker_it_went_up(question)
    end
  end

  def escalate_question(%Scope{}, _question_id, _reason, _opts), do: {:error, :needs_a_reason}

  @doc """
  Who a newly raised question starts with.

  An agent's question starts with the main agent — that is story 1052's routing
  and the reason this project has a main agent at all. Two askers are the
  exception and both for the same reason: there is nobody above them to route
  to. The main agent's own question is already a decision it could not make, and
  a question with no agent came from Claude Code, which talks to the person
  directly.
  """
  @spec holder_for(Scope.t(), String.t() | nil) :: String.t()
  def holder_for(%Scope{}, nil), do: "user"

  def holder_for(%Scope{} = scope, agent_id) when is_binary(agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, %{role: :main}} -> "user"
      {:ok, _agent} -> "main_agent"
      {:error, _reason} -> "user"
    end
  end

  @doc """
  Tell the project's main agent that one of its agents is waiting.

  Criterion 3265 — a question is delivered, not discovered. Story 1059 gives the
  main agent a cadence, which makes this look already-solved: a question raised
  now *will* be seen, at the next tick. The difference is a blocked agent
  waiting out a whole window for somebody who was idle throughout.

  Silent when there is no main agent running, which is ordinary rather than an
  error — the question is in the listing either way, and failing an agent's
  `ask_user` because nobody happened to be there to be told would lose the
  question to save the notification.
  """
  @spec question_raised(Scope.t(), map()) :: :ok
  def question_raised(%Scope{} = scope, %{agent_id: agent_id} = request)
      when is_binary(agent_id) do
    case main_agent_other_than(scope, agent_id) do
      nil ->
        :ok

      agent ->
        Agents.send_to_agent(agent.id, raised(request))
        :ok
    end
  end

  def question_raised(%Scope{}, _request), do: :ok

  # The main agent by role rather than by checkout. `Agents.main_agent/1`
  # answers "the agent on the designated copy", which is the right answer to a
  # different question and the wrong one here: several agents share a checkout,
  # and the first one found on it is whichever row came back first.
  defp main_agent_other_than(scope, asking_agent_id) do
    scope
    |> Agents.list_running()
    |> Enum.find(fn agent -> agent.role == :main and agent.id != asking_agent_id end)
  end

  defp raised(%{questions: questions, title: title}) do
    body = Enum.map_join(questions, "\n", fn q -> "- #{MapAccess.get(q, :question)}" end)

    """
    An agent is waiting on an answer: #{title}

    #{body}

    Answer it if the project already knows, and escalate it if the decision is
    the user's. Either way it is yours until you move it.
    """
  end

  # The asking agent hears that its question moved, so a chain it cannot see
  # does not look like silence. Criterion 3269 is the same fact read from the
  # asker's own side; this is the push, that is the pull, and an agent that
  # stopped after asking has only the push.
  defp tell_the_asker_it_went_up({:ok, escalated}, %OpenQuestion{agent_id: agent_id}) do
    Agents.send_to_agent(
      agent_id,
      "Your question went up to the user: #{escalated.escalation_reason}. " <>
        "It is still open and now waiting on them."
    )

    {:ok, escalated}
  end

  defp tell_the_asker_it_went_up(error, _question), do: error
end
