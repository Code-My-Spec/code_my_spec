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
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @doc """
  Every unanswered question raised by an agent of this project, oldest first.

  Oldest first because the list is a queue: the question that has been waiting
  longest is the work that has been stopped longest.
  """
  @spec list_open_questions(Scope.t()) :: [OpenQuestion.t()]
  def list_open_questions(%Scope{active_project_id: project_id}) when not is_nil(project_id) do
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
  Hand a question to the user, with the reason it could not be answered here.

  An update rather than a delete or an answer, which is the whole of criterion
  3264: the question stays exactly where it was and changes who is holding it.
  """
  @spec hand_to_user(String.t(), String.t()) :: {:ok, QuestionRequest.t()} | {:error, term()}
  def hand_to_user(question_id, reason) do
    QuestionRequest
    |> Repo.get(question_id)
    |> QuestionRequest.changeset(%{"holder" => "user", "escalation_reason" => reason})
    |> Repo.update()
  end
end
