defmodule CodeMySpec.Repo.Migrations.LinkTapOutsToDurableTasks do
  use Ecto.Migration

  def change do
    alter table(:permission_requests) do
      add :task_id, :string
    end
  end
end
