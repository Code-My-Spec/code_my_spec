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
  """

  def change do
    create(
      unique_index(:issues, [:title, :project_id],
        name: :issues_title_project_id_no_story_index,
        where: "story_id IS NULL"
      )
    )
  end
end
