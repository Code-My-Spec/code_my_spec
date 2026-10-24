defmodule CodeMySpec.MachineIdentityMigrationTest.Repo do
  use Ecto.Repo, otp_app: :code_my_spec, adapter: Ecto.Adapters.SQLite3
end

defmodule CodeMySpec.MachineIdentityMigrationTest do
  use ExUnit.Case, async: false
  alias CodeMySpec.MachineIdentityMigrationTest.Repo, as: TestRepo

  @version 20_261_024_230_000
  @path "priv/sqlite/migrations/20261024230000_unify_machine_identities.exs"

  setup_all do
    source =
      @path
      |> File.read!()
      |> String.replace(
        "CodeMySpec.Repo.Migrations.UnifyMachineIdentities",
        "CodeMySpec.MachineIdentityMigrationTest.Migration"
      )

    [{migration, _}] = Code.compile_string(source, @path)
    resource_path = "priv/sqlite/migrations/20261024231000_provider_machine_resource_identity.exs"

    resource_source =
      resource_path
      |> File.read!()
      |> String.replace(
        "CodeMySpec.Repo.Migrations.ProviderMachineResourceIdentity",
        "CodeMySpec.MachineIdentityMigrationTest.ResourceMigration"
      )

    [{resource_migration, _}] = Code.compile_string(resource_source, resource_path)
    %{migration: migration, resource_migration: resource_migration}
  end

  setup do
    start_supervised!({TestRepo, database: ":memory:", pool_size: 1})
    TestRepo.query!("CREATE TABLE accounts (id TEXT PRIMARY KEY)")
    TestRepo.query!("INSERT INTO accounts VALUES ('account')")

    TestRepo.query!(
      "CREATE TABLE devices (id TEXT PRIMARY KEY, account_id TEXT REFERENCES accounts(id), kind TEXT NOT NULL, provider TEXT, token_hash TEXT, inserted_at TEXT, updated_at TEXT)"
    )

    TestRepo.query!(
      "CREATE TABLE linked_servers (id TEXT PRIMARY KEY, account_id TEXT REFERENCES accounts(id), name TEXT, provider TEXT, environment TEXT, inserted_at TEXT, updated_at TEXT)"
    )

    TestRepo.query!(
      "CREATE TABLE environments (id TEXT PRIMARY KEY, management TEXT, server_id TEXT REFERENCES linked_servers(id) ON DELETE SET NULL, host TEXT)"
    )

    TestRepo.query!("CREATE INDEX environments_server_id_index ON environments(server_id)")

    TestRepo.query!(
      "CREATE TABLE working_copies (id TEXT PRIMARY KEY, device_id TEXT REFERENCES devices(id))"
    )

    TestRepo.query!(
      "CREATE TABLE app_instances (id TEXT PRIMARY KEY, device_id TEXT REFERENCES devices(id) ON DELETE CASCADE, environment_id TEXT REFERENCES environments(id) ON DELETE RESTRICT, working_copy_id TEXT REFERENCES working_copies(id), source_root TEXT, persistent INTEGER NOT NULL, \"default\" INTEGER NOT NULL)"
    )

    TestRepo.query!(
      "INSERT INTO devices VALUES ('laptop', 'account', 'local', 'local', 'original-hash', 'before', 'after')"
    )

    TestRepo.query!("INSERT INTO working_copies VALUES ('copy', 'laptop')")

    TestRepo.query!(
      "INSERT INTO linked_servers VALUES ('server', 'account', 'prod-box', 'hetzner', 'production', 'old', 'new')"
    )

    TestRepo.query!(
      "INSERT INTO environments VALUES ('prod', 'provisioned', 'server', 'example.com'), ('dev', 'harness', NULL, NULL)"
    )

    TestRepo.query!(
      "INSERT INTO app_instances VALUES ('deployment', 'laptop', 'prod', NULL, NULL, 1, 0), ('development', 'laptop', 'dev', 'copy', '/srv/app', 1, 1), ('local-runtime', 'laptop', 'prod', 'copy', '/srv/app', 1, 0)"
    )

    :ok
  end

  test "consolidates identity without touching harness credentials or checkout ownership", %{
    migration: migration,
    resource_migration: resource_migration
  } do
    assert :ok =
             Ecto.Migrator.up(TestRepo, @version, migration, log: false, migration_lock: false)

    assert TestRepo.query!(
             "SELECT id, provider, provider_name, purpose, kind, inserted_at, updated_at FROM devices WHERE id = 'server'"
           ).rows == [["server", "hetzner", "prod-box", "production", "cloud", "old", "new"]]

    assert TestRepo.query!("SELECT token_hash FROM devices WHERE id = 'laptop'").rows == [
             ["original-hash"]
           ]

    assert TestRepo.query!("SELECT device_id FROM working_copies WHERE id = 'copy'").rows == [
             ["laptop"]
           ]

    assert TestRepo.query!("SELECT id, device_id FROM app_instances ORDER BY id").rows == [
             ["deployment", "server"],
             ["development", "laptop"],
             ["local-runtime", "laptop"]
           ]

    assert TestRepo.query!("SELECT device_id, host FROM environments WHERE id = 'prod'").rows == [
             ["server", "example.com"]
           ]

    assert {:error, _} = TestRepo.query("DELETE FROM devices WHERE id = 'server'")

    assert :ok =
             Ecto.Migrator.up(TestRepo, 20_261_024_231_000, resource_migration,
               log: false,
               migration_lock: false
             )

    TestRepo.query!("UPDATE devices SET provider_resource_id = '123' WHERE id = 'server'")

    assert {:error, _} =
             TestRepo.query(
               "INSERT INTO devices (id, account_id, kind, provider, provider_resource_id) VALUES ('duplicate', 'account', 'cloud', 'hetzner', '123')"
             )

    assert TestRepo.query!("PRAGMA foreign_key_check").rows == []
    assert TestRepo.query!("PRAGMA foreign_keys").rows == [[1]]

    assert_raise Ecto.MigrationError, ~r/Machine identities cannot be split safely/, fn ->
      Ecto.Migrator.down(TestRepo, @version, migration, log: false, migration_lock: false)
    end

    assert TestRepo.query!("SELECT provider_name FROM devices WHERE id = 'server'").rows == [
             ["prod-box"]
           ]

    assert TestRepo.query!("SELECT token_hash FROM devices WHERE id = 'laptop'").rows == [
             ["original-hash"]
           ]

    assert TestRepo.query!("SELECT COUNT(*) FROM app_instances").rows == [[3]]
    assert TestRepo.query!("PRAGMA foreign_key_check").rows == []
    assert TestRepo.query!("PRAGMA foreign_keys").rows == [[1]]
  end

  test "a colliding UUID aborts atomically without absorbing another machine", %{
    migration: migration
  } do
    TestRepo.query!(
      "INSERT INTO devices VALUES ('server', 'account', 'local', NULL, 'keep-me', 'before', 'after')"
    )

    assert_raise Exqlite.Error, fn ->
      Ecto.Migrator.up(TestRepo, @version, migration, log: false, migration_lock: false)
    end

    assert TestRepo.query!("SELECT token_hash FROM devices WHERE id = 'server'").rows == [
             ["keep-me"]
           ]

    assert TestRepo.query!("SELECT name FROM linked_servers").rows == [["prod-box"]]

    refute Enum.any?(
             TestRepo.query!("PRAGMA table_info(devices)").rows,
             &(Enum.at(&1, 1) == "provider_name")
           )

    assert TestRepo.query!("PRAGMA foreign_keys").rows == [[1]]
  end
end
