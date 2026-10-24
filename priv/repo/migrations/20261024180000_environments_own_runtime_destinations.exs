defmodule CodeMySpec.Repo.Migrations.EnvironmentsOwnRuntimeDestinations do
  use Ecto.Migration

  def up do
    rename(table(:provisioning_environments), to: table(:environments))

    execute(
      "ALTER TABLE environments RENAME CONSTRAINT provisioning_environments_project_id_fkey TO environments_project_id_fkey"
    )

    execute(
      "ALTER TABLE environments RENAME CONSTRAINT provisioning_environments_server_id_fkey TO environments_server_id_fkey"
    )

    drop(
      index(:environments, [:project_id, :name],
        name: :provisioning_environments_project_id_name_index
      )
    )

    drop(index(:environments, [:server_id], name: :provisioning_environments_server_id_index))
    create(unique_index(:environments, [:project_id, :name]))
    create(index(:environments, [:server_id]))

    execute("""
    ALTER TABLE environments ADD COLUMN management varchar(255) NOT NULL DEFAULT 'provisioned'
    CONSTRAINT environments_management_check CHECK (management IN ('harness', 'provisioned'))
    """)

    alter table(:app_instances) do
      add(:environment_id, references(:environments, type: :binary_id, on_delete: :restrict))
    end

    create(index(:app_instances, [:environment_id]))
    flush()
    backfill_development()
  end

  def down do
    drop(index(:app_instances, [:environment_id]))

    alter table(:app_instances) do
      remove(:environment_id)
    end

    execute("DELETE FROM environments WHERE management = 'harness'")

    alter table(:environments) do
      remove(:management)
    end

    drop(index(:environments, [:project_id, :name]))
    drop(index(:environments, [:server_id]))

    execute(
      "ALTER TABLE environments RENAME CONSTRAINT environments_project_id_fkey TO provisioning_environments_project_id_fkey"
    )

    execute(
      "ALTER TABLE environments RENAME CONSTRAINT environments_server_id_fkey TO provisioning_environments_server_id_fkey"
    )

    rename(table(:environments), to: table(:provisioning_environments))
    create(unique_index(:provisioning_environments, [:project_id, :name]))
    create(index(:provisioning_environments, [:server_id]))
  end

  defp backfill_development do
    projects =
      repo().query!("""
      SELECT instances.project_id, MIN(instances.inserted_at) FROM app_instances instances
      JOIN working_copies copies ON copies.id = instances.working_copy_id
      WHERE copies.main = TRUE AND instances."default" = TRUE
      GROUP BY instances.project_id
      """).rows

    Enum.each(projects, fn [project_id, inserted_at] ->
      names =
        repo().query!("SELECT name FROM environments WHERE project_id = $1", [project_id]).rows

      taken = MapSet.new(names, fn [name] -> name end)
      name = development_name(taken)
      id = database_uuid()

      repo().query!(
        """
        INSERT INTO environments (id, project_id, name, management, inserted_at, updated_at)
        VALUES ($1, $2, $3, 'harness', $4, $4)
        """,
        [id, project_id, name, inserted_at]
      )

      repo().query!(
        """
        UPDATE app_instances SET environment_id = $1
        WHERE project_id = $2 AND "default" = TRUE AND working_copy_id IN
          (SELECT id FROM working_copies WHERE main = TRUE AND project_id = $2)
        """,
        [id, project_id]
      )
    end)
  end

  defp development_name(taken) do
    Stream.concat(
      ["dev", "dev-local"],
      Stream.iterate(2, &(&1 + 1)) |> Stream.map(&"dev-local-#{&1}")
    )
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp database_uuid do
    id = Ecto.UUID.generate()

    if repo().__adapter__() == Ecto.Adapters.Postgres do
      Ecto.UUID.dump!(id)
    else
      id
    end
  end
end
