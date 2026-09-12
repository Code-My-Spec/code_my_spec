defmodule CodeMySpec.Repo.Migrations.AResolvedQuestionKeepsItsAnswer do
  @moduledoc """
  `resolve_question` took only a `question_id` — resolving a red card
  recorded that somebody settled it and never how. An agent that passed a
  `resolution` string anyway had it silently dropped by the tool layer,
  because the schema never declared the field (5a7ef95b).

  Nullable and undefaulted: the three_amigos LiveView also resolves a
  question with a plain status toggle and no text box, and that path stays
  exactly as answerless as it is today.

  `IF NOT EXISTS` rather than a plain `add`, because this migration was
  renumbered after landing at a version another migration
  (`a_restart_remembers_what_it_was_for`) also claimed. Two files sharing one
  version means Ecto can execute both DDL bodies on a fresh database while
  recording only one of them as applied — so a database that ran this before
  the rename already has the column with no row saying so, and a plain `add`
  here fails it with "column already exists" the moment the renumbered
  version is recorded and re-run. Idempotent either way.
  """

  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE questions ADD COLUMN IF NOT EXISTS resolution text",
      "ALTER TABLE questions DROP COLUMN IF EXISTS resolution"
    )
  end
end
