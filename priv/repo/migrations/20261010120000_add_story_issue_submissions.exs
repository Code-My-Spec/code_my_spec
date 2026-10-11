defmodule CodeMySpec.Repo.Migrations.AddStoryIssueSubmissions do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add(:story_submission_ref, :uuid)
      add(:story_submission_revision, :text)
      add(:story_submission_evidence, :text)
      add(:story_submitted_at, :utc_datetime_usec)
      add(:story_submission_history, {:array, :map}, default: [], null: false)
    end
  end
end
