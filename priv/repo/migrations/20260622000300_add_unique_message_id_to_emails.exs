defmodule CodeMySpec.Repo.Migrations.AddUniqueMessageIdToEmails do
  use Ecto.Migration

  def change do
    # Lets inbound reconciliation upsert by Message-ID without duplicating when
    # the webhook and a manual sync (or a retry) both deliver the same email.
    # Partial: outbound rows have no message_id and shouldn't be constrained.
    create unique_index(:emails, [:message_id],
             where: "message_id IS NOT NULL",
             name: :emails_message_id_index
           )
  end
end
