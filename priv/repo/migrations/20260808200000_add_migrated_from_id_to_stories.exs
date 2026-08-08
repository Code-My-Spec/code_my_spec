defmodule CodeMySpec.Repo.Migrations.AddMigratedFromIdToStories do
  use Ecto.Migration

  @moduledoc """
  Which story this was before it was migrated.

  Story ids are per-deployment sequences, so a migration renumbers everything —
  and the ranges overlap, which is the part that bites. After migrating this
  project, `727` named "Agents working the same project do not collide" on the
  server and "Engineer trusts QA pass claims as audit-grade events" on the
  harness; guided intake was `990` on one and `875` on the other. Both answers
  are valid, so nothing errors: an operator or an agent asking either side by
  number gets a confident wrong story.

  There was no way to translate. The payload carries `local_id` to wire up
  references inside the import transaction, and then discards it, leaving title
  as the only correspondence — which is also what the importer dedupes on, so a
  retitled story is a new story and a duplicated title is one story.

  Recording the source id fixes both: references can be translated mechanically,
  and a re-run can recognise its own earlier rows by something stronger than a
  string a human edits.

  Unique per project rather than globally: two projects may legitimately migrate
  from harnesses whose sequences overlap, and they are separate graphs. Nullable
  because a story authored here has no source, which is the ordinary case.
  """

  def change do
    alter table(:stories) do
      add :migrated_from_id, :bigint
    end

    create unique_index(:stories, [:project_id, :migrated_from_id],
             where: "migrated_from_id IS NOT NULL",
             name: :stories_project_id_migrated_from_id_index
           )
  end
end
