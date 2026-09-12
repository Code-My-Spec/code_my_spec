defmodule CodeMySpec.Repo.Migrations.AResolvedQuestionKeepsItsAnswer do
  @moduledoc """
  `resolve_question` took only a `question_id` — resolving a red card
  recorded that somebody settled it and never how. An agent that passed a
  `resolution` string anyway had it silently dropped by the tool layer,
  because the schema never declared the field (5a7ef95b).

  Nullable and undefaulted: the three_amigos LiveView also resolves a
  question with a plain status toggle and no text box, and that path stays
  exactly as answerless as it is today.
  """

  use Ecto.Migration

  def change do
    alter table(:questions) do
      add :resolution, :text
    end
  end
end
