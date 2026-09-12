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
      CodeMySpec.Conversations,
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
  alias CodeMySpec.MainAgent.AgentWork
  alias CodeMySpec.MainAgent.OpenQuestion
  alias CodeMySpec.MainAgent.QuestionsRepository
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
  defdelegate list_agent_work(scope), to: WorkRepository

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
