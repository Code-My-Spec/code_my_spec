defmodule CodeMySpec.Repo.Migrations.ARunNamesItsRequesterWaitersAndOrphanState do
  use Ecto.Migration

  # Who asked, who waits, and whether its harness went away were keys inside
  # `requested_by` and `stats`. They are the run's own state, queried on every
  # stop hook, so they are columns and a table.
  def up do
    alter table(:analysis_runs) do
      add :requester_agent_id, :string
      add :orphaned, :boolean
      add :settled, :string
    end

    create table(:analysis_run_waiters, primary_key: false) do
      add :run_id, references(:analysis_runs, on_delete: :delete_all), null: false
      add :agent_id, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:analysis_run_waiters, [:run_id, :agent_id])
    create index(:analysis_run_waiters, [:agent_id])
    create index(:analysis_runs, [:requester_agent_id])

    flush()

    execute("""
    UPDATE analysis_runs
       SET requester_agent_id = requested_by->>'agent_id',
           orphaned = coalesce((stats->>'orphaned') = 'true', false),
           settled = stats->>'settled'
    """)

    execute("""
    INSERT INTO analysis_run_waiters (run_id, agent_id, inserted_at)
    SELECT r.id, w.agent_id, now()
      FROM analysis_runs r,
           jsonb_array_elements_text(r.requested_by->'waiters') AS w(agent_id)
     WHERE jsonb_typeof(r.requested_by->'waiters') = 'array'
    ON CONFLICT DO NOTHING
    """)

    alter table(:analysis_runs) do
      modify :orphaned, :boolean, null: false
    end
  end

  def down do
    drop table(:analysis_run_waiters)

    alter table(:analysis_runs) do
      remove :requester_agent_id
      remove :orphaned
      remove :settled
    end
  end
end
