defmodule CodeMySpec.Questions do
  @moduledoc """
  The Questions context — Three Amigos red cards (parked questions).

  Questions are first-class records produced when neither the agent nor
  the PM can answer something in the moment. They belong to a Story and
  cycle through `:open → :resolved | :deferred`. Only OPEN questions
  count against the readiness gate (`scenarios > questions`); resolved
  and deferred are historical.

  Direct-DB implementation via `QuestionsRepository`. The
  `:questions_implementation` config key is kept as a swap point for test
  doubles.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all

  alias CodeMySpec.Questions.Question
  alias CodeMySpec.Questions.QuestionsRepository
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  defp impl do
    Application.get_env(:code_my_spec, :questions_implementation, QuestionsRepository)
  end

  @doc """
  Subscribes to scoped notifications about question changes.

  Broadcasts match the pattern:

    * {:question_created, %Question{}}
    * {:question_updated, %Question{}}
    * {:question_deleted, %Question{}}

  """
  def subscribe(%Scope{} = scope) do
    key = scope.active_account_id
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:questions")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.active_account_id
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:questions", message)

    GraphInputs.announce(scope, "Questions", GraphInputs.story_entities(message), :project_wide)
  end

  def create_question(scope, story_id, attrs) do
    case impl().create_question(scope, story_id, attrs) do
      {:ok, question} = ok ->
        broadcast(scope, {:question_created, question})
        ok

      other ->
        other
    end
  end

  def list_questions_for_story(scope, story_id),
    do: impl().list_questions_for_story(scope, story_id)

  def get_question(scope, id), do: impl().get_question(scope, id)

  def update_question(scope, %Question{} = question, attrs) do
    case impl().update_question(scope, question, attrs) do
      {:ok, updated} = ok ->
        broadcast(scope, {:question_updated, updated})
        ok

      other ->
        other
    end
  end

  @doc """
  Marks a question as resolved, with the answer that resolved it.

  `resolution` is the artifact — the playbook's reason a red card blocks a
  session is that "an unanswered question that nobody ever returns to is how
  a story gets built on a guess," and `status: :resolved` only ever recorded
  the receipt, not the answer (5a7ef95b). Optional and nullable: the
  three_amigos LiveView resolves with a plain status toggle and has no text
  box to supply one.
  """
  def resolve_question(scope, %Question{} = question, resolution \\ nil),
    do: update_question(scope, question, %{status: :resolved, resolution: resolution})

  @doc "Marks a question as deferred (parked indefinitely)."
  def defer_question(scope, %Question{} = question),
    do: update_question(scope, question, %{status: :deferred})

  @doc "Reopens a previously resolved or deferred question."
  def reopen_question(scope, %Question{} = question),
    do: update_question(scope, question, %{status: :open})

  @doc "Deletes a question (PM-side admin action). Broadcasts on success."
  def delete_question(scope, %Question{} = question) do
    case impl().delete_question(scope, question) do
      {:ok, deleted} = ok ->
        broadcast(scope, {:question_deleted, deleted})
        ok

      other ->
        other
    end
  end
end
