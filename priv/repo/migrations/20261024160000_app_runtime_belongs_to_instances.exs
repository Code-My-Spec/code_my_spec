defmodule CodeMySpec.Repo.Migrations.AppRuntimeBelongsToInstances do
  use Ecto.Migration

  def up do
    create table(:app_instances, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:device_id, references(:devices, type: :binary_id, on_delete: :nilify_all))
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

    create(index(:app_instances, [:project_id]))
    create(index(:app_instances, [:device_id]))
    create(index(:app_instances, [:working_copy_id]))

    create(
      unique_index(:app_instances, [:project_id, :working_copy_id],
        where: "\"default\" = true AND working_copy_id IS NOT NULL",
        name: :app_instances_one_default_per_source_index
      )
    )

    execute("""
    INSERT INTO app_instances (
      id, project_id, device_id, working_copy_id, "default", source_root,
      status, checked_at, url, "commit", serving_commit, preview_status,
      preview_checked_at, preview_url, preview_tunnel_id, preview_tunnel_secret,
      promotion_sync, persistent, port_mode, database_mode, after_promote,
      inserted_at, updated_at
    )
    SELECT id, project_id, device_id, id, TRUE, root,
      app_status, app_checked_at, app_url, app_commit, app_serving_commit,
      preview_status, preview_checked_at, preview_url, preview_tunnel_id,
      preview_tunnel_secret, COALESCE(promotion_sync, '{}'), main,
      CASE WHEN main THEN 'configured' ELSE 'allocated' END,
      CASE WHEN main THEN 'configured' ELSE 'clone' END,
      main, inserted_at, updated_at
    FROM working_copies
    """)

    alter table(:working_copies) do
      remove(:app_status)
      remove(:app_checked_at)
      remove(:app_url)
      remove(:app_commit)
      remove(:app_serving_commit)
      remove(:preview_status)
      remove(:preview_checked_at)
      remove(:preview_url)
      remove(:preview_tunnel_id)
      remove(:preview_tunnel_secret)
      remove(:promotion_sync)
    end
  end

  def down do
    alter table(:working_copies) do
      add(:app_status, :string)
      add(:app_checked_at, :utc_datetime_usec)
      add(:app_url, :text)
      add(:app_commit, :text)
      add(:app_serving_commit, :text)
      add(:preview_status, :string)
      add(:preview_checked_at, :utc_datetime_usec)
      add(:preview_url, :text)
      add(:preview_tunnel_id, :text)
      add(:preview_tunnel_secret, :binary)
      add(:promotion_sync, :map, default: %{})
    end

    execute("""
    UPDATE working_copies SET
      app_status = (SELECT status FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      app_checked_at = (SELECT checked_at FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      app_url = (SELECT url FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      app_commit = (SELECT "commit" FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      app_serving_commit = (SELECT serving_commit FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      preview_status = (SELECT preview_status FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      preview_checked_at = (SELECT preview_checked_at FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      preview_url = (SELECT preview_url FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      preview_tunnel_id = (SELECT preview_tunnel_id FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      preview_tunnel_secret = (SELECT preview_tunnel_secret FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE),
      promotion_sync = (SELECT promotion_sync FROM app_instances WHERE app_instances.working_copy_id = working_copies.id AND app_instances."default" = TRUE)
    """)

    drop(table(:app_instances))
  end
end
