defmodule CodeMySpec.AppInstancesMigrationTest.Repo do
  use Ecto.Repo,
    otp_app: :code_my_spec,
    adapter: Ecto.Adapters.SQLite3
end

defmodule CodeMySpec.AppInstancesMigrationTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.AppInstancesMigrationTest.Repo, as: TestRepo

  @version 20_261_024_160_000
  @migration "priv/sqlite/migrations/20261024160000_app_runtime_belongs_to_instances.exs"

  test "backfill preserves runtime records, encrypted bytes, policy and null roots" do
    start_supervised!({TestRepo, database: ":memory:", pool_size: 1})

    create_legacy_schema()
    seed_legacy_rows()
    migration = compile_sqlite_migration()

    assert :ok =
             Ecto.Migrator.up(TestRepo, @version, migration,
               log: false,
               migration_lock: false
             )

    rows =
      TestRepo.query!(
        "SELECT id, working_copy_id, source_root, status, checked_at, url, \"commit\", serving_commit, preview_status, preview_checked_at, preview_url, preview_tunnel_id, preview_tunnel_secret, promotion_sync, persistent, port_mode, database_mode, after_promote, inserted_at, updated_at FROM app_instances ORDER BY id"
      ).rows

    assert length(rows) == 2
    assert [null_root, rooted] = rows

    assert Enum.at(null_root, 0) == "copy-null-root"
    assert Enum.at(null_root, 1) == "copy-null-root"
    assert is_nil(Enum.at(null_root, 2))
    assert Enum.at(null_root, 3) == "down"
    assert Enum.at(null_root, 4) == "2026-10-01T01:02:03.000000Z"
    assert Enum.at(null_root, 6) == "old-commit-null"
    assert Enum.at(null_root, 8) == nil
    assert Enum.at(null_root, 11) == "tunnel-null"
    assert Enum.at(null_root, 12) == <<0, 255, 1, 128>>
    assert Enum.at(null_root, 13) == ~s({"attempt":2})
    assert Enum.at(null_root, 14) == 0
    assert Enum.at(null_root, 15) == "allocated"
    assert Enum.at(null_root, 16) == "clone"
    assert Enum.at(null_root, 17) == 0
    assert Enum.at(null_root, 18) == "2026-10-01T00:00:00.000000Z"
    assert Enum.at(null_root, 19) == "2026-10-01T01:02:03.000000Z"

    assert Enum.at(rooted, 0) == "copy-rooted"
    assert Enum.at(rooted, 1) == "copy-rooted"
    assert Enum.at(rooted, 2) == "/srv/rooted"
    assert Enum.at(rooted, 3) == "serving"
    assert Enum.at(rooted, 4) == "2026-10-02T01:02:03.000000Z"
    assert Enum.at(rooted, 6) == "old-commit-rooted"
    assert Enum.at(rooted, 7) == "served-commit-rooted"
    assert Enum.at(rooted, 8) == "serving"
    assert Enum.at(rooted, 10) == "https://preview.example"
    assert Enum.at(rooted, 11) == "tunnel-rooted"
    assert Enum.at(rooted, 12) == <<4, 3, 2, 1>>
    assert Enum.at(rooted, 13) == ~s({"receipt":"kept"})
    assert Enum.at(rooted, 14) == 1
    assert Enum.at(rooted, 15) == "configured"
    assert Enum.at(rooted, 16) == "configured"
    assert Enum.at(rooted, 17) == 1
    assert Enum.at(rooted, 18) == "2026-10-02T00:00:00.000000Z"
    assert Enum.at(rooted, 19) == "2026-10-02T01:02:03.000000Z"

    columns = TestRepo.query!("PRAGMA table_info(working_copies)").rows
    refute Enum.any?(columns, &(Enum.at(&1, 1) == "app_status"))
    refute Enum.any?(columns, &(Enum.at(&1, 1) == "preview_tunnel_secret"))
    refute Enum.any?(columns, &(Enum.at(&1, 1) == "promotion_sync"))
  end

  defp create_legacy_schema do
    TestRepo.query!("CREATE TABLE projects (id TEXT PRIMARY KEY)")
    TestRepo.query!("CREATE TABLE devices (id TEXT PRIMARY KEY)")

    TestRepo.query!("""
    CREATE TABLE working_copies (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      device_id TEXT,
      root TEXT,
      main INTEGER NOT NULL,
      app_status TEXT,
      app_checked_at TEXT,
      app_url TEXT,
      app_commit TEXT,
      app_serving_commit TEXT,
      preview_status TEXT,
      preview_checked_at TEXT,
      preview_url TEXT,
      preview_tunnel_id TEXT,
      preview_tunnel_secret BLOB,
      promotion_sync TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    TestRepo.query!("INSERT INTO projects (id) VALUES ('project-1')")
    TestRepo.query!("INSERT INTO devices (id) VALUES ('device-1')")
  end

  defp compile_sqlite_migration do
    source = File.read!(@migration)
    original = "defmodule CodeMySpec.Repo.Migrations.AppRuntimeBelongsToInstances do"
    test_module = "defmodule CodeMySpec.AppInstancesMigrationTest.SQLiteMigration do"
    source = String.replace(source, original, test_module, global: false)

    [{module, _binary}] = Code.compile_string(source, @migration)
    module
  end

  defp seed_legacy_rows do
    TestRepo.query!("""
    INSERT INTO working_copies VALUES (
      'copy-null-root', 'project-1', 'device-1', NULL, 0,
      'down', '2026-10-01T01:02:03.000000Z', NULL, 'old-commit-null', NULL,
      NULL, NULL, NULL, 'tunnel-null', X'00FF0180', '{"attempt":2}',
      '2026-10-01T00:00:00.000000Z', '2026-10-01T01:02:03.000000Z'
    )
    """)

    TestRepo.query!("""
    INSERT INTO working_copies VALUES (
      'copy-rooted', 'project-1', 'device-1', '/srv/rooted', 1,
      'serving', '2026-10-02T01:02:03.000000Z', 'http://localhost:4000',
      'old-commit-rooted', 'served-commit-rooted', 'serving',
      '2026-10-02T01:02:04.000000Z', 'https://preview.example', 'tunnel-rooted',
      X'04030201', '{"receipt":"kept"}',
      '2026-10-02T00:00:00.000000Z', '2026-10-02T01:02:03.000000Z'
    )
    """)
  end
end
