defmodule CodeMySpec.Repo.Migrations.AddAttachmentsToConversationMessages do
  use Ecto.Migration

  def change do
    alter table(:conversation_messages) do
      # A list of attachment maps copied into our S3 bucket, e.g.
      # %{"s3_key" => ..., "filename" => ..., "content_type" => ..., "size" => ...}.
      add :attachments, :jsonb, null: false, default: "[]"
    end
  end
end
