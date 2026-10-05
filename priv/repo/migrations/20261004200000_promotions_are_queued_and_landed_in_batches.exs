defmodule CodeMySpec.Repo.Migrations.PromotionsAreQueuedAndLandedInBatches do
  @moduledoc """
  Promote-queue step 2 (John, 2026-10-04): an agent enqueues a certified-ready
  commit and the project's queue gates candidates in batches, landing each green
  batch on main. One row per enqueued candidate.

  `batch_id` is set only while a candidate is in a batch, and `result` only once
  one has an outcome, so neither is NOT NULL.
  """
  use Ecto.Migration

  def change do
    create table(:promotion_queue_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false

      add :working_copy_id,
          references(:working_copies, type: :binary_id, on_delete: :delete_all),
          null: false

      add :commit, :string, null: false
      add :story_number, :integer
      add :requested_by_agent_id, :binary_id
      add :restart, :boolean, null: false
      add :status, :string, null: false
      add :batch_id, :binary_id
      add :result, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:promotion_queue_entries, [:project_id, :status, :inserted_at])
  end
end
