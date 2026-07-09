defmodule CodeMySpec.Repo.Migrations.CreateEmailAttachments do
  use Ecto.Migration

  def change do
    create table(:email_attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider_attachment_id, :string
      add :filename, :string
      add :content_type, :string
      add :content_disposition, :string
      add :content_id, :string
      add :size, :integer
      add :s3_key, :string, null: false
      add :email_id, references(:emails, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:email_attachments, [:email_id])
    create unique_index(:email_attachments, [:email_id, :provider_attachment_id])
  end
end
