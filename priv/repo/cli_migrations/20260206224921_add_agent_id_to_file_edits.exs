defmodule CodeMySpec.Repo.Migrations.AddAgentIdToFileEdits do
  use Ecto.Migration

  def change do
    alter table(:file_edits) do
      add :agent_id, :string
    end

    create index(:file_edits, [:agent_id], where: "agent_id IS NOT NULL")
  end
end
