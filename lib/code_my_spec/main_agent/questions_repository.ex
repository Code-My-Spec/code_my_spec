defmodule CodeMySpec.MainAgent.QuestionsRepository do
  @moduledoc """
  Reads and writes the questions one project's agents have open.

  ## Scoped to the project, not the checkout

  Criterion 3261. Nearly everything else here is scoped to a working copy and
  is right to be — a verdict about code belongs to the tree it was computed
  from. A question is not a verdict about code. It is somebody waiting, and it
  waits whatever checkout it was raised on, so narrowing this query to the copy
  the reader happens to be standing on would hide every question raised
  anywhere else and report nothing about having done so.

  The project comes through the agent rather than off the question, because
  that is where it actually is: `question_requests` keys to a user, and the
  agent is the only thing on the row that knows which project this was.

  ## Every agent, not only the running ones

  Criterion 3263. An agent is restarted whenever its harness reconnects, its
  machine reboots, or somebody promotes, so "the agent that asked is stopped"
  is the ordinary case. Joining against running agents would drop the question
  with the process, and drop it silently — there is no entry left to be short
  and no agent left to complain.
  """

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.MainAgent.OpenQuestion
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc """
  Every unanswered question raised by an agent of this project, oldest first.

  Oldest first because the list is a queue: the question that has been waiting
  longest is the work that has been stopped longest.
  """
  @spec list_open_questions(Scope.t()) :: [OpenQuestion.t()]
  def list_open_questions(%Scope{active_project_id: project_id}) when not is_nil(project_id) do
    (pending_questions(project_id) ++ pending_permissions(project_id))
    |> Enum.sort_by(& &1.asked_at, DateTime)
  end

  defp pending_questions(project_id) do
    from(q in QuestionRequest,
      join: a in Agent,
      on: a.id == q.agent_id,
      left_join: w in WorkingCopy,
      on: w.id == a.working_copy_id,
      where: a.project_id == ^project_id and q.status == "pending",
      order_by: [asc: q.inserted_at],
      select: {q, a, w}
    )
    |> Repo.all()
    |> Enum.map(fn {request, agent, working_copy} ->
      OpenQuestion.new(request, agent, working_copy)
    end)
  end

  # The other half of what stops an agent, and it was missing.
  #
  # `Notifications.awaiting_answer?/1` — the predicate `StopDecision.wake/2`
  # consults before it will wake anything — is `pending_question? or
  # pending_permission?`. A listing that unions only the first half cannot
  # explain the gate, so an agent held off the graph by a `tap_out` shows up
  # here as nothing at all.
  #
  # That is not hypothetical. Agent `880c7713` asked to leave the loop at 12:38,
  # nobody recorded a decision, and it spent seven hours unreachable while
  # `list_agent_work` reported it running, continuous and idle with 17
  # actionable requirements. This listing — which calls itself "everything the
  # agents on this project are waiting on, in one place" — showed nothing.
  # Issue `8cb3f626`.
  #
  # Merged rather than returned separately, and sorted with the questions, for
  # the reason the queue exists: the reader is asking "which of my agents are
  # stopped, and why", and that question has one answer. `kind` on the struct
  # is how a caller tells an answer from a decision.
  defp pending_permissions(project_id) do
    from(p in PermissionRequest,
      join: a in Agent,
      on: a.id == p.agent_id,
      left_join: w in WorkingCopy,
      on: w.id == a.working_copy_id,
      where: a.project_id == ^project_id and p.status == "pending",
      order_by: [asc: p.inserted_at],
      select: {p, a, w}
    )
    |> Repo.all()
    |> Enum.map(fn {request, agent, working_copy} ->
      OpenQuestion.from_permission(request, agent, working_copy)
    end)
  end

  @doc """
  One of this project's open questions, by id.

  Scoped the same way the listing is, so a question belonging to another
  project's agents is `:not_found` here rather than something this project can
  act on — the main agent owns a project and its reach stops there.
  """
  @spec fetch_open_question(Scope.t(), String.t()) ::
          {:ok, OpenQuestion.t()} | {:error, :not_found}
  def fetch_open_question(%Scope{} = scope, question_id) do
    case Enum.find(list_open_questions(scope), &(&1.id == question_id)) do
      nil -> {:error, :not_found}
      question -> {:ok, question}
    end
  end

  @doc """
  Questions this project's user has already answered, matching some words.

  Answered only, which is criterion 3256's own distinction: a precedent is by
  definition settled, and an open question matching the same words is evidence
  that this has been asked and *not* decided.

  Scoped to the user rather than to the project's agents, unlike
  `list_open_questions/1`. A decision is the person's and outlives the agent
  that prompted it — and a decision made while answering one project's question
  is still that person's decision.
  """
  @spec search_answers(Scope.t(), String.t()) :: [map()]
  def search_answers(%Scope{user: %{id: user_id}}, query) when is_binary(query) do
    pattern = "%#{query}%"

    from(q in QuestionRequest,
      where: q.user_id == ^user_id and q.status == "answered",
      where: fragment("?::text ILIKE ?", q.questions, ^pattern),
      order_by: [desc: q.updated_at],
      limit: 20
    )
    |> Repo.all()
  end

  def search_answers(%Scope{}, _query), do: []

  @doc "One answered question by id, or nil."
  @spec fetch_answered(Scope.t(), String.t()) :: QuestionRequest.t() | nil
  def fetch_answered(%Scope{user: %{id: user_id}}, id) do
    Repo.get_by(QuestionRequest, id: id, user_id: user_id, status: "answered")
  end

  def fetch_answered(%Scope{}, _id), do: nil

  @doc """
  Hand a question to the user, with the reason it could not be answered here.

  An update rather than a delete or an answer, which is the whole of criterion
  3264: the question stays exactly where it was and changes who is holding it.
  """
  @spec hand_to_user(String.t(), String.t(), String.t() | nil) ::
          {:ok, QuestionRequest.t()} | {:error, term()}
  def hand_to_user(question_id, reason, as \\ nil) do
    request = Repo.get(QuestionRequest, question_id)

    request
    |> QuestionRequest.changeset(%{
      "holder" => "user",
      "escalation_reason" => reason,
      "questions" => framed(request.questions, as)
    })
    |> Repo.update()
  end

  # The decision in the user's terms, with the agent's original kept.
  #
  # Criterion 3253. A question arriving as module names and a stack trace is
  # technically delivered and practically useless — the person it reached cannot
  # answer without asking somebody what it means, so it sits in the inbox while
  # every part of the delivery looks successful.
  #
  # Kept rather than replaced, because a user who wants to know why is entitled
  # to, and an escalation that discards the original leaves the answer unmoored
  # from the thing it decides.
  defp framed(questions, nil), do: questions

  defp framed([first | rest], as),
    do: [
      Map.merge(first, %{"question" => as, "asked_as" => MapAccess.get(first, :question)}) | rest
    ]

  defp framed(questions, _as), do: questions
end
