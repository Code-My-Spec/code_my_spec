defmodule CodeMySpec.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :end_user_id, :string
      add :end_user_email, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversations, [:account_id, :project_id, :end_user_email])
    create index(:conversations, [:account_id])

    create table(:conversation_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :string, null: false
      add :sender_id, :string
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversation_messages, [:conversation_id])
  end
end
