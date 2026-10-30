defmodule CodeMySpec.Repo.Migrations.PromotionCandidatesBelongToTasks do
  use Ecto.Migration

  def change do
    alter table(:promotion_queue_entries) do
      add :task_id, :string
    end

    create index(:promotion_queue_entries, [:project_id, :task_id])
  end
end
