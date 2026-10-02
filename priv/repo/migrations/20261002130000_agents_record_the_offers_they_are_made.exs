defmodule CodeMySpec.Repo.Migrations.AgentsRecordTheOffersTheyAreMade do
  use Ecto.Migration

  # Offers, step 1 (b75b0198): every nudge an agent is sent, with its outcome.
  # Record only; nothing reads these to decide anything yet.
  def change do
    create table(:offers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :working_copy_id, :binary_id
      add :kind, :string, null: false
      add :subject_type, :string, null: false
      add :subject_key, :string
      add :attempt, :integer, null: false
      # open | claimed | declined | ignored | superseded | expired | n_a | undelivered
      add :status, :string, null: false
      add :outcome_at, :utc_datetime_usec
      add :reason, :text
      add :note, :text
      add :next_step, :string
      add :template_version, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:offers, [:agent_id, :status])
    create index(:offers, [:agent_id, :kind, :subject_type, :subject_key])
    create index(:offers, [:project_id, :kind, :status])

    create table(:offer_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :offer_id, references(:offers, type: :binary_id, on_delete: :delete_all), null: false

      add :message_id,
          references(:conversation_messages, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:offer_messages, [:offer_id, :message_id])
    create index(:offer_messages, [:message_id])
  end
end
