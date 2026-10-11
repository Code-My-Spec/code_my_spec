defmodule CodeMySpec.Repo.Migrations.AddStoryQaReviews do
  use Ecto.Migration

  def change do
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
      add(:review_started_at, :utc_datetime_usec)
      add(:review_certified_at, :utc_datetime_usec)
      add(:stale, :boolean, null: false, default: false)
    end

    alter table(:qa_invalidations) do
      add(:cause, :string)
      add(:actor_id, :string)
      add(:issue_id, :binary_id)
      add(:submission_ref, :string)
    end
  end
end
