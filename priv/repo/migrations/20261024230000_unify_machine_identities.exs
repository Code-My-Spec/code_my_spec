defmodule CodeMySpec.Repo.Migrations.UnifyMachineIdentities do
  use Ecto.Migration

  def up do
    alter table(:devices) do
      add(:provider_name, :string)
      add(:provider_resource_id, :string)
      add(:purpose, :string)
    end

    create(unique_index(:devices, [:account_id, :provider, :provider_name]))

    # A UUID collision must fail, never merge two machines by name or address.
    execute("""
    INSERT INTO devices (id, account_id, kind, provider, provider_name, purpose, inserted_at, updated_at)
    SELECT id, account_id, 'cloud', provider, name, environment, inserted_at, updated_at FROM linked_servers
    """)

    drop(constraint(:environments, "environments_server_id_fkey"))
    rename(table(:environments), :server_id, to: :device_id)
    drop(index(:environments, [:server_id], name: :environments_server_id_index))
    create(index(:environments, [:device_id]))

    alter table(:environments) do
      modify(:device_id, references(:devices, type: :binary_id, on_delete: :restrict))
    end

    execute("""
    UPDATE app_instances SET device_id = (
      SELECT device_id FROM environments WHERE environments.id = app_instances.environment_id
    ) WHERE environment_id IN (SELECT id FROM environments WHERE management = 'provisioned')
      AND working_copy_id IS NULL AND source_root IS NULL AND persistent = TRUE AND "default" = FALSE
    """)

    drop(table(:linked_servers))
  end

  def down do
    raise Ecto.MigrationError,
          "Machine identities cannot be split safely after enrollment; restore a database backup to undo this migration"
  end
end
