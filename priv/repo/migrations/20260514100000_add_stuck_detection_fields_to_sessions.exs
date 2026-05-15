defmodule CodeMySpec.Repo.Migrations.AddStuckDetectionFieldsToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :last_eval_feedback_hash, :string
      add :eval_feedback_count, :integer
    end
  end
end
