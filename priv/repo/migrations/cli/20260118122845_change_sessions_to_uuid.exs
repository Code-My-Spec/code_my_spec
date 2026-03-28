defmodule CodeMySpec.Repo.Migrations.ChangeSessionsToUuid do
  use Ecto.Migration

  @doc """
  SQLite migration to convert sessions.id and session_id from INTEGER to UUID.
  Uses table recreation since SQLite doesn't support ALTER COLUMN or DROP CONSTRAINT.
  """
  def up do
    repo = CodeMySpec.Repo

    # Step 1: Get all existing sessions and create UUID mapping
    existing_sessions =
      repo.query!("SELECT id, type, agent, environment, execution_mode, status, state, interactions, external_conversation_id, project_id, account_id, user_id, component_id, session_id, inserted_at, updated_at FROM sessions")

    # Create mapping of old integer IDs to new UUIDs
    id_mapping =
      existing_sessions.rows
      |> Enum.map(fn [id | _rest] -> {id, Ecto.UUID.generate()} end)
      |> Map.new()

    # Step 2: Get all existing interactions
    existing_interactions =
      repo.query!("SELECT id, session_id, step_name, command, result, completed_at, inserted_at, updated_at FROM interactions")

    # Step 3: Drop indexes on sessions (required before dropping the table)
    execute "DROP INDEX IF EXISTS sessions_project_id_index"
    execute "DROP INDEX IF EXISTS sessions_account_id_index"
    execute "DROP INDEX IF EXISTS sessions_user_id_index"
    execute "DROP INDEX IF EXISTS sessions_component_id_index"
    execute "DROP INDEX IF EXISTS sessions_session_id_index"
    execute "DROP INDEX IF EXISTS sessions_external_conversation_id_index"

    # Step 4: Drop indexes on interactions
    execute "DROP INDEX IF EXISTS interactions_session_id_index"
    execute "DROP INDEX IF EXISTS interactions_session_id_inserted_at_index"

    # Step 5: Drop the old tables (interactions first due to FK)
    execute "DROP TABLE IF EXISTS interactions"
    execute "DROP TABLE IF EXISTS sessions"

    # Step 6: Create new sessions table with UUID primary key
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string
      add :agent, :string
      add :environment, :string
      add :execution_mode, :string, default: "manual"
      add :status, :string
      add :state, :string
      add :interactions, :string
      add :external_conversation_id, :string
      add :project_id, references(:projects, type: :binary_id, on_delete: :nothing)
      add :account_id, :integer
      add :user_id, :integer
      add :component_id, :binary_id
      add :session_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    # Step 7: Create new interactions table with UUID session_id
    create table(:interactions, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :step_name, :string
      add :command, :string, null: false
      add :result, :string
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Step 8: Create indexes
    create index(:sessions, [:project_id])
    create index(:sessions, [:account_id])
    create index(:sessions, [:user_id])
    create index(:sessions, [:component_id])
    create index(:sessions, [:session_id])
    create index(:sessions, [:external_conversation_id])
    create index(:interactions, [:session_id])
    create index(:interactions, [:session_id, :inserted_at])

    flush()

    # Step 9: Reinsert sessions with new UUIDs
    Enum.each(existing_sessions.rows, fn [old_id, type, agent, environment, execution_mode, status, state, interactions, external_conversation_id, project_id, account_id, user_id, component_id, old_session_id, inserted_at, updated_at] ->
      new_id = Map.get(id_mapping, old_id)
      new_session_id = if old_session_id, do: Map.get(id_mapping, old_session_id), else: nil

      {:ok, new_id_binary} = Ecto.UUID.dump(new_id)
      new_session_id_binary = if new_session_id do
        {:ok, binary} = Ecto.UUID.dump(new_session_id)
        binary
      else
        nil
      end

      repo.query!(
        "INSERT INTO sessions (id, type, agent, environment, execution_mode, status, state, interactions, external_conversation_id, project_id, account_id, user_id, component_id, session_id, inserted_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
        [new_id_binary, type, agent, environment, execution_mode, status, state, interactions, external_conversation_id, project_id, account_id, user_id, component_id, new_session_id_binary, inserted_at, updated_at]
      )
    end)

    # Step 10: Reinsert interactions with new UUID session_ids
    Enum.each(existing_interactions.rows, fn [id, old_session_id, step_name, command, result, completed_at, inserted_at, updated_at] ->
      new_session_id = Map.get(id_mapping, old_session_id)

      if new_session_id do
        {:ok, new_session_id_binary} = Ecto.UUID.dump(new_session_id)

        repo.query!(
          "INSERT INTO interactions (id, session_id, step_name, command, result, completed_at, inserted_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
          [id, new_session_id_binary, step_name, command, result, completed_at, inserted_at, updated_at]
        )
      end
    end)
  end

  def down do
    raise "This migration cannot be safely reversed. UUID to integer conversion would lose data."
  end
end