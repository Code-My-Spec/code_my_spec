defmodule CodeMySpec.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :type, :string
      add :agent, :string
      add :environment, :string
      add :execution_mode, :string, default: "manual"
      add :status, :string
      add :state, :map
      add :interactions, :map
      add :external_conversation_id, :string

      # CLI doesn't have accounts or users tables, but stores IDs
      add :project_id, references(:projects, on_delete: :nothing)
      add :account_id, :integer
      add :user_id, :integer
      add :component_id, :integer
      add :session_id, references(:sessions, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:sessions, [:project_id])
    create index(:sessions, [:account_id])
    create index(:sessions, [:user_id])
    create index(:sessions, [:component_id])
    create index(:sessions, [:session_id])
    create index(:sessions, [:external_conversation_id])
  end
end
