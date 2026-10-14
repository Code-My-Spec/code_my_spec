defmodule CodeMySpec.Repo.Migrations.AStorylessIssueTitleIsUniquePerProject do
  use Ecto.Migration

  @moduledoc """
  Issue b2752ae3: the existing `unique_index(:issues, [:title, :story_id, :project_id])`
  protects nothing for a fault issue, because every one of them has a `nil`
  `story_id` -- and Postgres treats NULL as distinct from NULL in a unique
  index, so any number of rows with the same title and project, both with a
  null story_id, can coexist without ever tripping that constraint. That is
  how "A restart changed nothing: <reason>" was filed repeatedly for the same
  agent and reason: the check-then-insert in `Agents.Main.file_fault/5` raced,
  and nothing at the database layer would have stopped it even without a race.

  A second, partial index closes the gap this one unique index cannot: unique
  on (title, project_id) specifically where story_id is null.

  Issue b4b2266c: creating that index crashed app startup wherever real data
  already had two or more storyless issues sharing a title and project (two
  `dismissed` rows titled "test", five months old, found on this copy's own
  dev database) -- unrelated to any fault at all, just coincidence that
  predates this fix. Deduping first, by renaming every row after the oldest
  in each (title, project_id) group rather than deleting it, keeps the
  records (QA's own recommendation) and lets the index creation succeed
  everywhere, not just on databases that happen to have no collisions yet.
  """

  @doc false
  def dedup_storyless_duplicate_titles_sql do
    """
    WITH ranked AS (
      SELECT id,
             row_number() OVER (
               PARTITION BY title, project_id
               ORDER BY inserted_at ASC, id ASC
             ) AS rn
      FROM issues
      WHERE story_id IS NULL
    )
    UPDATE issues
    SET title = issues.title || ' (duplicate ' || issues.id || ')'
    FROM ranked
    WHERE issues.id = ranked.id AND ranked.rn > 1
    """
  end

  def change do
    execute(dedup_storyless_duplicate_titles_sql())

    create(
      unique_index(:issues, [:title, :project_id],
        name: :issues_title_project_id_no_story_index,
        where: "story_id IS NULL"
      )
    )
  end
end
