defmodule CodeMySpec.Repo.Migrations.UnifyMachineIdentities do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: execute(fn -> rebuild_safely(&unify/0) end)

  def down do
    raise Ecto.MigrationError,
          "Machine identities cannot be split safely after enrollment; restore a database backup to undo this migration"
  end

  # SQLite cannot replace a foreign key in place. All changes remain atomic;
  # temporarily disabling FK actions prevents dropping the old parent from
  # deleting its app instances during the table rebuild.
  defp rebuild_safely(fun), do: repo().checkout(fn -> rebuild_on_connection(fun) end)

  defp rebuild_on_connection(fun) do
    repo().query!("PRAGMA foreign_keys = OFF")

    try do
      case repo().transaction(fn ->
             fun.()

             case repo().query!("PRAGMA foreign_key_check").rows do
               [] ->
                 :ok

               violations ->
                 raise "Machine identity migration left invalid foreign keys: #{inspect(violations)}"
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> raise "Machine identity migration failed: #{inspect(reason)}"
      end
    after
      repo().query!("PRAGMA foreign_keys = ON")
    end
  end

  defp unify do
    for field <- ~w(provider_name provider_resource_id purpose) do
      repo().query!("ALTER TABLE devices ADD COLUMN #{field} TEXT")
    end

    repo().query!(
      "CREATE UNIQUE INDEX devices_account_id_provider_provider_name_index ON devices (account_id, provider, provider_name)"
    )

    repo().query!("""
    INSERT INTO devices (id, account_id, kind, provider, provider_name, purpose, inserted_at, updated_at)
    SELECT id, account_id, 'cloud', provider, name, environment, inserted_at, updated_at FROM linked_servers
    """)

    repo().query!("ALTER TABLE environments RENAME COLUMN server_id TO device_id")

    rebuild_environments(
      "linked_servers",
      "devices",
      "SET NULL",
      "RESTRICT",
      "server_id",
      "device_id"
    )

    repo().query!("""
    UPDATE app_instances SET device_id = (
      SELECT device_id FROM environments WHERE environments.id = app_instances.environment_id
    ) WHERE environment_id IN (SELECT id FROM environments WHERE management = 'provisioned')
      AND working_copy_id IS NULL AND source_root IS NULL AND persistent = TRUE AND "default" = FALSE
    """)

    repo().query!("DROP TABLE linked_servers")
  end

  defp rebuild_environments(old_parent, new_parent, old_action, new_action, old_field, new_field) do
    [[sql]] =
      repo().query!(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'environments'"
      ).rows

    indexes =
      repo().query!(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'environments' AND sql IS NOT NULL"
      ).rows

    sql =
      sql
      |> String.replace(
        ~r/CREATE TABLE ["`]?environments["`]?/i,
        "CREATE TABLE environments_rebuilt"
      )
      |> String.replace(
        ~r/REFERENCES\s+["`]?#{old_parent}["`]?\s*\([^)]*\)\s*ON DELETE #{old_action}/i,
        "REFERENCES #{new_parent}(id) ON DELETE #{new_action}"
      )
      |> String.replace("environments_#{old_field}_fkey", "environments_#{new_field}_fkey")

    repo().query!(sql)
    repo().query!("INSERT INTO environments_rebuilt SELECT * FROM environments")
    repo().query!("DROP TABLE environments")
    repo().query!("ALTER TABLE environments_rebuilt RENAME TO environments")

    Enum.each(indexes, fn [index_sql] ->
      repo().query!(
        String.replace(
          index_sql,
          "environments_#{old_field}_index",
          "environments_#{new_field}_index"
        )
      )
    end)
  end
end
