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
      plan
      |> Turn.ask_changeset(length(turns) + 1, question)
      |> Repo.insert()
    end
  end

  @doc "Records an answer. Written immediately so a failing boot cannot take it."
  @spec answer(Turn.t(), String.t()) :: {:ok, Turn.t()} | {:error, Ecto.Changeset.t()}
  def answer(%Turn{} = turn, text) do
    turn |> Turn.answer_changeset(text) |> Repo.update()
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
