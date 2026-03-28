defmodule CodeMySpec.Repo.Migrations.CreateStories do
  use Ecto.Migration

  def change do
    create table(:stories) do
      add :title, :string, null: false
      add :description, :string, null: false
      add :acceptance_criteria, {:array, :string}, null: false, default: []
      add :status, :string, default: "in_progress"
      add :locked_at, :utc_datetime
      add :lock_expires_at, :utc_datetime
      add :locked_by, :integer

      # CLI doesn't have accounts, users, or versions tables
      add :account_id, :integer
      add :project_id, :binary_id
      add :component_id, references(:components, type: :binary_id, on_delete: :nilify_all)
      add :first_version_id, :integer
      add :current_version_id, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:stories, [:account_id])
    create index(:stories, [:project_id])
    create index(:stories, [:component_id])
    create unique_index(:stories, [:title, :project_id])
  end
end
