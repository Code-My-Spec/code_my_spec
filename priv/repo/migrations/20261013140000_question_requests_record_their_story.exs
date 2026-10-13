defmodule CodeMySpec.Repo.Migrations.QuestionRequestsRecordTheirStory do
  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :story_id, :integer
    end

    create index(:question_requests, [:user_id, :story_id, :status])
  end
end
