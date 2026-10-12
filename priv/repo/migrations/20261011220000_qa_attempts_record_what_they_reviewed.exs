defmodule CodeMySpec.Repo.Migrations.QaAttemptsRecordWhatTheyReviewed do
  @moduledoc """
  A QA attempt records the certification it reviewed itself; `qa_story_reviews`
  held only that and goes. A story records the certification its QA must have
  reviewed, which certification may carry from an earlier commit.
  """
  use Ecto.Migration

  def up do
    alter table(:stories) do
      add(:qa_reviewed_commit, :string)
      add(:qa_reviewed_at, :utc_datetime_usec)
    end

    alter table(:qa_attempts) do
      add(:reviewed_commit, :string)
      add(:reviewed_submissions, :map)
    end

    flush()

    execute("""
    UPDATE stories SET qa_reviewed_commit = qa_ready_commit, qa_reviewed_at = qa_ready_at
    WHERE qa_ready_commit IS NOT NULL
    """)

    execute("""
    UPDATE qa_attempts a
    SET reviewed_commit = r.certified_revision, reviewed_submissions = r.submissions
    FROM qa_story_reviews r
    WHERE a.review_id = r.id
    """)

    alter table(:qa_attempts) do
      remove(:review_id)
    end

    drop(table(:qa_story_reviews))
  end

  def down do
    create table(:qa_story_reviews, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:task_id, :string, null: false)
      add(:story_id, references(:stories, on_delete: :delete_all), null: false)
      add(:certified_revision, :string, null: false)
      add(:certified_at, :utc_datetime_usec, null: false)
      add(:submissions, :map, null: false)
      add(:started_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:qa_story_reviews, [:task_id]))

    alter table(:qa_attempts) do
      add(:review_id, references(:qa_story_reviews, type: :binary_id))
    end

    flush()

    execute("""
    INSERT INTO qa_story_reviews (id, task_id, story_id, certified_revision, certified_at, submissions, started_at)
    SELECT DISTINCT ON (a.task_id) gen_random_uuid(), a.task_id, a.story_id, a.reviewed_commit,
           a.review_certified_at, a.reviewed_submissions, a.review_started_at
    FROM qa_attempts a
    WHERE a.reviewed_commit IS NOT NULL AND a.task_id IS NOT NULL
    ORDER BY a.task_id, a.submitted_at DESC
    """)

    execute("""
    UPDATE qa_attempts a SET review_id = r.id FROM qa_story_reviews r WHERE r.task_id = a.task_id
    """)

    alter table(:qa_attempts) do
      remove(:reviewed_commit)
      remove(:reviewed_submissions)
    end

    alter table(:stories) do
      remove(:qa_reviewed_commit)
      remove(:qa_reviewed_at)
    end
  end
end
