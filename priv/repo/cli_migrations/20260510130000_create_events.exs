defmodule CodeMySpec.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :event_type, :string, null: false
      add :data, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:events, [:event_type])
    create index(:events, [:event_type, :inserted_at])
  end
end
