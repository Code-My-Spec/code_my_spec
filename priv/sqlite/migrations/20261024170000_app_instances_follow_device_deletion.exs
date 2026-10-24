defmodule CodeMySpec.Repo.Migrations.AppInstancesFollowDeviceDeletion do
  use Ecto.Migration

  def up, do: rebuild(:delete_all)
  def down, do: rebuild(:nilify_all)

  # SQLite cannot alter a foreign key. Preserve every runtime field and index
  # while retaining the restriction on directly deleting an instance's checkout.
  defp rebuild(on_delete) do
    create table(:app_instances_rebuilt, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:device_id, references(:devices, type: :binary_id, on_delete: on_delete))
      add(:working_copy_id, references(:working_copies, type: :binary_id, on_delete: :restrict))
      add(:default, :boolean, null: false, default: true)
      add(:source_root, :text)
      add(:status, :string)
      add(:checked_at, :utc_datetime_usec)
      add(:url, :text)
      add(:commit, :text)
      add(:serving_commit, :text)
      add(:preview_status, :string)
      add(:preview_checked_at, :utc_datetime_usec)
      add(:preview_url, :text)
      add(:preview_tunnel_id, :text)
      add(:preview_tunnel_secret, :binary)
      add(:promotion_sync, :map, null: false, default: %{})
      add(:persistent, :boolean, null: false, default: false)
      add(:port_mode, :string, null: false)
      add(:database_mode, :string, null: false)
      add(:database_source, :text)
      add(:after_promote, :boolean, null: false, default: false)
      timestamps(type: :utc_datetime_usec)
    end

    execute("INSERT INTO app_instances_rebuilt SELECT * FROM app_instances")
    drop(table(:app_instances))
    rename(table(:app_instances_rebuilt), to: table(:app_instances))

    create(index(:app_instances, [:project_id]))
    create(index(:app_instances, [:device_id]))
    create(index(:app_instances, [:working_copy_id]))

    create(
      unique_index(:app_instances, [:project_id, :working_copy_id],
        where: "\"default\" = true AND working_copy_id IS NOT NULL",
        name: :app_instances_one_default_per_source_index
      )
    )
  end
end
