defmodule CodeMySpec.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh_key, :text, null: false
      add :auth_key, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:push_subscriptions, [:user_id])
    create unique_index(:push_subscriptions, [:endpoint])
  end
end
