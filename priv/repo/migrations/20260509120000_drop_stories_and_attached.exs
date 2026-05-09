defmodule CodeMySpec.Repo.Migrations.DropStoriesAndAttached do
  use Ecto.Migration

  # Story domain (stories, criteria, bdd_rules, questions, personas, persona_stories,
  # story_tags) moved to the local CLI app. This drops the server-side tables.
  # PaperTrail's `versions` table is intentionally left in place — kept for
  # possible reuse and to avoid clobbering any historical audit data.

  def up do
    alter table(:files) do
      remove :story_id
    end

    drop_if_exists table(:story_tags)
    drop_if_exists table(:persona_stories)
    drop_if_exists table(:questions)
    drop_if_exists table(:criteria)
    drop_if_exists table(:bdd_rules)
    drop_if_exists table(:personas)
    drop_if_exists table(:stories)
  end

  def down do
    raise Ecto.MigrationError,
      message: "Irreversible: stories domain has moved to the local CLI app and " <>
               "the schemas/migrations no longer exist on the server. Restore from a " <>
               "pre-drop snapshot if you need this data back."
  end
end
