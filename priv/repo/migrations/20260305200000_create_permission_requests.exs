defmodule CodeMySpec.Repo.Migrations.CreatePermissionRequests do
  use Ecto.Migration

  def change do
    create table(:permission_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :tool_name, :string, null: false
      add :tool_input, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :decision, :string

      timestamps(type: :utc_datetime)
    end

    create index(:permission_requests, [:user_id])
    create index(:permission_requests, [:status])
  end
end
