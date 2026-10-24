defmodule CodeMySpec.EnvironmentsMigrationTest.Repo do
  use Ecto.Repo, otp_app: :code_my_spec, adapter: Ecto.Adapters.SQLite3
end

defmodule CodeMySpec.EnvironmentsMigrationTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.EnvironmentsMigrationTest.Repo, as: TestRepo

  @version 20_261_024_180_000
  @migration "priv/sqlite/migrations/20261024180000_environments_own_runtime_destinations.exs"

  test "existing deployment destinations survive while main runtimes gain harness environments" do
    start_supervised!({TestRepo, database: ":memory:", pool_size: 1})
    create_legacy_schema()
    seed_legacy_rows()
    legacy = TestRepo.query!("SELECT * FROM provisioning_environments ORDER BY id").rows
    migration = compile_migration()
    options = [log: false, migration_lock: false]

    assert :ok = Ecto.Migrator.up(TestRepo, @version, migration, options)

    assert TestRepo.query!("""
           SELECT id, project_id, name, host, server_name, ip, server_id,
             first_deployed_at, inserted_at, updated_at
           FROM environments WHERE management = 'provisioned' ORDER BY id
           """).rows == legacy

    assert TestRepo.query!("""
           SELECT instances.id, environments.name, environments.management
           FROM app_instances instances
           LEFT JOIN environments ON environments.id = instances.environment_id
           ORDER BY instances.id
           """).rows == [
             ["main-1", "dev-local-2", "harness"],
             ["main-2", "dev", "harness"],
             ["persistent-qa", nil, nil],
             ["temporary-qa", nil, nil]
           ]

    assert {:error, _} = TestRepo.query("DELETE FROM environments WHERE management = 'harness'")

    assert {:error, _} =
             TestRepo.query(
               "UPDATE app_instances SET environment_id = 'missing' WHERE id = 'main-1'"
             )

    assert {:error, _} = TestRepo.query("UPDATE environments SET management = 'unsupported'")
    assert {:error, _} = TestRepo.query("UPDATE environments SET management = NULL")

    assert {:error, _} =
             TestRepo.query("UPDATE environments SET name = 'dev' WHERE name = 'dev-local-2'")

    assert TestRepo.query!("PRAGMA foreign_key_check").rows == []
    assert :ok = Ecto.Migrator.down(TestRepo, @version, migration, options)
    assert TestRepo.query!("SELECT * FROM provisioning_environments ORDER BY id").rows == legacy
    assert TestRepo.query!("SELECT COUNT(*) FROM app_instances").rows == [[4]]
    assert TestRepo.query!("PRAGMA foreign_key_check").rows == []

    assert :ok = Ecto.Migrator.up(TestRepo, @version, migration, options)

    assert TestRepo.query!("SELECT COUNT(*) FROM environments WHERE management = 'harness'").rows ==
             [[2]]

    assert TestRepo.query!("PRAGMA foreign_key_check").rows == []
  end

  defp create_legacy_schema do
    TestRepo.query!("CREATE TABLE projects (id TEXT PRIMARY KEY)")
    TestRepo.query!("CREATE TABLE linked_servers (id TEXT PRIMARY KEY)")

    TestRepo.query!("""
    CREATE TABLE provisioning_environments (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      host TEXT,
      server_name TEXT,
      ip TEXT,
      server_id TEXT REFERENCES linked_servers(id) ON DELETE SET NULL,
      first_deployed_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    TestRepo.query!(
      "CREATE UNIQUE INDEX provisioning_environments_project_id_name_index ON provisioning_environments (project_id, name)"
    )

    TestRepo.query!(
      "CREATE INDEX provisioning_environments_server_id_index ON provisioning_environments (server_id)"
    )

    TestRepo.query!("""
    CREATE TABLE working_copies (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES projects(id),
      main INTEGER NOT NULL
    )
    """)

    TestRepo.query!("""
    CREATE TABLE app_instances (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES projects(id),
      working_copy_id TEXT REFERENCES working_copies(id) ON DELETE RESTRICT,
      "default" INTEGER NOT NULL,
      persistent INTEGER NOT NULL,
      inserted_at TEXT NOT NULL
    )
    """)
  end

  defp seed_legacy_rows do
    TestRepo.query!("INSERT INTO projects VALUES ('project-1'), ('project-2'), ('project-3')")
    TestRepo.query!("INSERT INTO linked_servers VALUES ('server-1')")

    for {id, name} <- [{"env-1", "dev"}, {"env-2", "dev-local"}, {"env-3", "prod"}] do
      TestRepo.query!(
        """
        INSERT INTO provisioning_environments VALUES (
          $1, 'project-1', $2, 'example.com', 'original-server', '192.0.2.1',
          'server-1', '2026-10-01T01:02:03.000000Z',
          '2026-09-01T00:00:00.000000Z', '2026-10-01T01:02:03.000000Z'
        )
        """,
        [id, name]
      )
    end

    TestRepo.query!("""
    INSERT INTO working_copies VALUES
      ('copy-main-1', 'project-1', 1), ('copy-main-2', 'project-2', 1),
      ('copy-qa', 'project-1', 0)
    """)

    TestRepo.query!("""
    INSERT INTO app_instances VALUES
      ('main-1', 'project-1', 'copy-main-1', 1, 1, '2026-10-01T00:00:00.000000Z'),
      ('main-2', 'project-2', 'copy-main-2', 1, 1, '2026-10-01T00:00:00.000000Z'),
      ('persistent-qa', 'project-1', 'copy-qa', 1, 1, '2026-10-01T00:00:00.000000Z'),
      ('temporary-qa', 'project-1', 'copy-qa', 0, 0, '2026-10-01T00:00:00.000000Z')
    """)
  end

  defp compile_migration do
    source =
      @migration
      |> File.read!()
      |> String.replace(
        "defmodule CodeMySpec.Repo.Migrations.EnvironmentsOwnRuntimeDestinations do",
        "defmodule CodeMySpec.EnvironmentsMigrationTest.SQLiteMigration do",
        global: false
      )

    [{module, _binary}] = Code.compile_string(source, @migration)
    module
  end
end
