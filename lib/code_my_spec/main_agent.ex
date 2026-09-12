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
      CodeMySpec.Conversations,
      CodeMySpec.Devices,
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

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Issues
  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.Machinery
  alias CodeMySpec.MainAgent.MachineryRepository
  alias CodeMySpec.MainAgent.OpenQuestion
  alias CodeMySpec.MainAgent.QuestionsRepository
  alias CodeMySpec.MainAgent.RestartRepository
  alias CodeMySpec.MainAgent.WorkRepository
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

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

  def restart_agent(%Scope{}, _agent_id, _reason), do: {:error, :needs_a_reason}

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
      Conversations.record_orchestrator_action(agent, "Restarted: #{reason}", kind: "restart")

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
      agent's to perform — the harness serves every working copy on that \
      machine, other projects included, and restarting it takes their in-flight \
      work with it. Somebody who can weigh that needs to decide.
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

  defp raise_fault(scope, working_copy, title, description) do
    Issues.create_issue(scope, %{
      title: title,
      severity: :high,
      scope: :framework,
      description: description,
      source_path: working_copy
    })
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
  @spec escalate_question(Scope.t(), String.t(), String.t()) ::
          {:ok, OpenQuestion.t()} | {:error, :not_found | :needs_a_reason | term()}
  def escalate_question(%Scope{} = scope, question_id, reason)
      when is_binary(reason) and reason != "" do
    with {:ok, question} <- QuestionsRepository.fetch_open_question(scope, question_id),
         {:ok, _updated} <- QuestionsRepository.hand_to_user(question_id, reason) do
      QuestionsRepository.fetch_open_question(scope, question_id)
      |> tell_the_asker_it_went_up(question)
    end
  end

  def escalate_question(%Scope{}, _question_id, _reason), do: {:error, :needs_a_reason}

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
    scope
    |> main_agent_other_than(agent_id)
    |> Conversations.record_orchestrator_action(raised(request),
      kind: "question",
      tool: "list_open_questions"
    )

    :ok
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
    Conversations.record_orchestrator_action(
      agent_id,
      "Your question went up to the user: #{escalated.escalation_reason}. " <>
        "It is still open and now waiting on them.",
      kind: "escalation"
    )

    {:ok, escalated}
  end

  defp tell_the_asker_it_went_up(error, _question), do: error
end
