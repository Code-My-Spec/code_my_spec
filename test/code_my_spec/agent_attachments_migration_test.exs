defmodule CodeMySpec.AgentAttachmentsMigrationTest.Repo do
  use Ecto.Repo, otp_app: :code_my_spec, adapter: Ecto.Adapters.SQLite3
end

defmodule CodeMySpec.AgentAttachmentsMigrationTest do
  use ExUnit.Case, async: false
  alias CodeMySpec.AgentAttachmentsMigrationTest.Repo, as: TestRepo
  @filename "20261024200000_agent_working_copy_attachments.exs"
  @version 20_261_024_200_000

  test "paired migration creates matching attachment constraints on SQLite and reverses cleanly" do
    sqlite = Path.join("priv/sqlite/migrations", @filename)
    assert File.read!(sqlite) == File.read!(Path.join("priv/repo/migrations", @filename))

    source =
      sqlite
      |> File.read!()
      |> String.replace(
        "CodeMySpec.Repo.Migrations.AgentWorkingCopyAttachments",
        "CodeMySpec.AgentAttachmentsMigrationTest.Migration"
      )

    [{migration, _}] = Code.compile_string(source, sqlite)
    start_supervised!({TestRepo, database: ":memory:", pool_size: 1})

    for table <- ~w(agents working_copies projects accounts) do
      TestRepo.query!("CREATE TABLE #{table} (id TEXT PRIMARY KEY)")
      TestRepo.query!("INSERT INTO #{table} (id) VALUES ('one'), ('two')")
    end

    options = [log: false, migration_lock: false]
    assert :ok = Ecto.Migrator.up(TestRepo, @version, migration, options)
    fields = TestRepo.query!("PRAGMA table_info(agent_working_copy_attachments)").rows

    assert MapSet.new(Enum.map(fields, &Enum.at(&1, 1))) ==
             MapSet.new(
               ~w(id agent_id working_copy_id project_id account_id inserted_at updated_at)
             )

    assert {:ok, _} = insert("a", "one", "one")
    assert {:error, _} = insert("duplicate", "one", "one")
    assert {:ok, _} = insert("b", "one", "two")
    assert {:error, _} = insert("foreign", "missing", "two")
    assert TestRepo.query!("PRAGMA foreign_key_check").rows == []
    TestRepo.query!("DELETE FROM working_copies WHERE id = 'one'")
    assert TestRepo.query!("SELECT id FROM agent_working_copy_attachments").rows == [["b"]]
    TestRepo.query!("DELETE FROM agents WHERE id = 'one'")
    assert TestRepo.query!("SELECT id FROM agent_working_copy_attachments").rows == []
    assert :ok = Ecto.Migrator.down(TestRepo, @version, migration, options)

    assert TestRepo.query!(
             "SELECT name FROM sqlite_master WHERE name = 'agent_working_copy_attachments'"
           ).rows == []

    assert TestRepo.query!("SELECT COUNT(*) FROM projects").rows == [[2]]
  end

  defp insert(id, agent, copy) do
    TestRepo.query(
      """
      INSERT INTO agent_working_copy_attachments
        (id, agent_id, working_copy_id, project_id, account_id, inserted_at, updated_at)
      VALUES (?, ?, ?, 'one', 'one', '2026-10-24T00:00:00.000000Z', '2026-10-24T00:00:00.000000Z')
      """,
      [id, agent, copy]
    )
  end
end
