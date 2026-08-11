defmodule CodeMySpec.Repo.Migrations.AddNumberToStories do
  @moduledoc """
  A durable identifier for a story, so its files can stop naming its primary key.

  `BddSpecs.spec_file_path/2` builds `test/spex/<story.id>_<slug>/`, and its own
  comment records why that is wrong: "the id on migration, which renumbers every
  story". It does, and the files do not follow. Measured on this project the
  drift is a uniform 51 — `test/spex/811_user_sees_the_agents_task_queue…` names
  a real story 811, "Onboarding lives at /app", while the story that owns those
  spex is 862.

  Everything downstream that read the number out of a path inherited the error
  silently, because a number resolving to *a* story is indistinguishable from
  one resolving to the right story.

  Seeded from the filenames rather than from the ids, so existing paths keep
  meaning what they say and nothing on disk has to move. That is safe here:
  across this database, 88 distinct spex directory numbers, and zero of them
  span more than one story.

  Stories with no spex directory get a number above the highest one in use, so
  minting never collides with a name already on disk.

  No default on the column — schema defaults belong on the schema. It stays
  nullable here on purpose: adding NOT NULL in the same migration as the column
  broke every story insert with 23502, because the schema did not yet know the
  field existed. That cost 349 exunit failures and 33 spex. The constraint
  belongs in a follow-up, once every creation path has been minting for long
  enough to trust.
  """
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:stories) do
      add :number, :integer
    end

    flush()

    seed_from_spec_paths()
    mint_the_rest()

    # Deliberately left nullable. The constraint belongs in a follow-up, after
    # `Story` sets the field and creation mints one — adding it here made every
    # story insert fail with 23502, because the schema does not know the column
    # exists yet. That cost 349 exunit failures and 33 spex the first time.
    #
    # A column that existing rows satisfy and new rows cannot is the worst
    # ordering: the backfill looks like success and the breakage arrives on the
    # next write.

    # Per project, not global: two projects each numbering from their own
    # filenames must not collide.
    create unique_index(:stories, [:project_id, :number])
  end

  def down do
    drop index(:stories, [:project_id, :number])

    alter table(:stories) do
      remove :number
    end
  end

  # The directory number a story's criteria already live under.
  defp seed_from_spec_paths do
    repo().update_all(
      from(s in "stories",
        join: c in "criteria",
        on: c.story_id == s.id,
        where: not is_nil(c.spec_path) and c.spec_path != "",
        update: [
          set: [
            number:
              fragment(
                "NULLIF(split_part(replace(?, 'test/spex/', ''), '_', 1), '')::integer",
                c.spec_path
              )
          ]
        ]
      ),
      []
    )
  end

  # Everything with no spex on disk, numbered above the highest name in use so a
  # later file cannot collide with one that already exists.
  defp mint_the_rest do
    repo().query!("""
    WITH ceiling AS (
      SELECT project_id, COALESCE(MAX(number), 0) AS top
      FROM stories
      GROUP BY project_id
    ),
    numbered AS (
      SELECT s.id,
             c.top + ROW_NUMBER() OVER (PARTITION BY s.project_id ORDER BY s.id) AS n
      FROM stories s
      JOIN ceiling c ON c.project_id = s.project_id
      WHERE s.number IS NULL
    )
    UPDATE stories SET number = numbered.n
    FROM numbered WHERE stories.id = numbered.id
    """)
  end
end
