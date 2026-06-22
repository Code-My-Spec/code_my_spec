defmodule CodeMySpec.Repo.Migrations.CreateMailTables do
  use Ecto.Migration

  def change do
    create table(:mailboxes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :address, :string, null: false
      add :catch_all, :boolean, null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mailboxes, [:project_id, :address])
    create index(:mailboxes, [:user_id])

    create table(:emails, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :direction, :string, null: false
      add :from_address, :string
      add :to_address, :string
      add :correspondent, :string
      add :subject, :string
      add :body_text, :text
      add :body_html, :text
      add :provider_id, :string
      add :message_id, :string
      add :in_reply_to, :string
      add :mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:emails, [:mailbox_id])
    create index(:emails, [:mailbox_id, :correspondent])
  end
end
