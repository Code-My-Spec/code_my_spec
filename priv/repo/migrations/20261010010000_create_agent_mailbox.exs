defmodule CodeMySpec.Repo.Migrations.CreateAgentMailbox do
  use Ecto.Migration

  def change do
    create table(:agent_mailbox) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :message_id,
          references(:conversation_messages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :delivery_ref, :text, null: false
      add :event, :text, null: false
      add :state, :text, null: false, default: "queued"
      add :generation, :text
      add :claimed_at, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :diagnostic, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_mailbox, [:message_id])
    create unique_index(:agent_mailbox, [:delivery_ref])
    create index(:agent_mailbox, [:agent_id, :id])

    create unique_index(:agent_mailbox, [:agent_id],
             name: :agent_mailbox_one_owner,
             where: "state IN ('claimed', 'consumed', 'uncertain')"
           )
  end
end
