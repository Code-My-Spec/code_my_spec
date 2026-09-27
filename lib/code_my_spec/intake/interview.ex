defmodule CodeMySpec.Intake.Interview do
  @moduledoc """
  The story interview, run while the workspace is still coming up.

  Two things make this the interview rather than a form:

    * **It pays out.** After at most four answers the visitor is shown the
      rules those answers imply. The cap is a pacing rule, not a feature —
      the interview lands straight after an instant-gratification moment, and
      fifteen minutes of typing there collapses the pace.
    * **It outlives the boot.** Every answer is written down as it is given,
      so a workspace that dies mid-conversation costs the visitor nothing.
  """

  import Ecto.Query

  alias CodeMySpec.Conversations
  alias CodeMySpec.Intake.{Interviewer, Plan, Turn}
  alias CodeMySpec.Repo

  @question_cap 4

  @doc "How many questions the visitor answers before they are shown the rules."
  @spec question_cap() :: pos_integer()
  def question_cap, do: @question_cap

  @doc "Every turn on this plan, oldest first."
  @spec turns(Plan.t()) :: [Turn.t()]
  def turns(%Plan{id: plan_id}) do
    Repo.all(from t in Turn, where: t.plan_id == ^plan_id, order_by: [asc: t.position])
  end

  @doc """
  The turn the visitor is currently being asked, starting the interview if it
  has not begun.

  Returns `{:done, turns}` once the cap is reached — there is nothing further
  to ask, and the caller should derive the rules.
  """
  @spec current_turn(Plan.t()) ::
          {:ok, Turn.t()} | {:done, [Turn.t()]} | {:error, term()}
  def current_turn(%Plan{} = plan) do
    plan |> turns() |> resume(plan)
  end

  defp resume(turns, %Plan{} = plan) do
    case Enum.find(turns, &is_nil(&1.answer)) do
      %Turn{} = unanswered -> {:ok, unanswered}
      nil -> ask_next(plan, turns)
    end
  end

  defp ask_next(%Plan{}, turns) when length(turns) >= @question_cap, do: {:done, turns}

  defp ask_next(%Plan{} = plan, turns) do
    with {:ok, question} <- Interviewer.ask(plan, turns) do
      case plan |> Turn.ask_changeset(length(turns) + 1, question) |> Repo.insert() do
        {:ok, _turn} = ok ->
          echo(plan, :assistant, question)
          ok

        error ->
          error
      end
    end
  end

  @doc "Records an answer. Written immediately so a failing boot cannot take it."
  @spec answer(Turn.t(), String.t()) :: {:ok, Turn.t()} | {:error, Ecto.Changeset.t()}
  def answer(%Turn{} = turn, text) do
    case turn |> Turn.answer_changeset(text) |> Repo.update() do
      {:ok, updated} = ok ->
        echo(Repo.get!(Plan, updated.plan_id), :user, text)
        ok

      error ->
        error
    end
  end

  # Mirrored into the project's own conversation as it happens, same reason
  # every answer is written down immediately: `agent-conversation` reads this
  # as it goes rather than from a single copy taken at signup, which would
  # have left every question asked after conversion invisible there.
  #
  # `find_or_create_agent_conversation/3` adopts this row (by its `"intake:"`
  # prefix) once a real agent starts, so this and `Intake.convert/2`'s own
  # copy of the shaping half land in the same thread. `nil` before conversion
  # is defensive rather than reachable — the interview only runs on
  # `/build/workspace`, after `Intake.convert/2` has already set these.
  defp echo(%Plan{account_id: nil}, _role, _text), do: :ok
  defp echo(%Plan{project_id: nil}, _role, _text), do: :ok

  defp echo(%Plan{} = plan, role, text) do
    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
        plan.account_id,
        plan.project_id,
        "intake:#{plan.id}"
      )

    Conversations.add_message(conversation, role, text)
  end

  @doc """
  The rules the answers imply.

  Only called once the cap is reached — deriving rules from a half-finished
  conversation would put words in the visitor's mouth.
  """
  @spec rules(Plan.t()) :: {:ok, [String.t()]} | {:error, term()}
  def rules(%Plan{} = plan) do
    answered = plan |> turns() |> Enum.filter(& &1.answer)

    Interviewer.derive(plan, answered)
  end

  @doc "How far through the interview the visitor is, for showing the pace."
  @spec answered_count(Plan.t()) :: non_neg_integer()
  def answered_count(%Plan{} = plan) do
    plan |> turns() |> Enum.count(& &1.answer)
  end
end
