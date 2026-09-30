defmodule CodeMySpec.Requirements.StoryPromotedRenameMigrationTest do
  @moduledoc """
  f4786ba1: `code_on_running_copy` is renamed `story_promoted`. Stored
  requirement rows and agents' embedded task lists carry the name, so the
  migration renames them rather than leaving rows the graph no longer knows.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  @version 20_260_929_220_000
  @migration "priv/repo/migrations/20260929220000_code_on_running_copy_is_renamed_story_promoted.exs"

  defp migration do
    [{module, _}] = Code.require_file(@migration)
    module
  end

  defp names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT name FROM #{table} WHERE name LIKE '%promoted%' OR name = 'code_on_running_copy'"
      )

    List.flatten(rows)
  end

  defp insert_requirement(table, name) do
    Repo.query!(
      "INSERT INTO #{table} (name, description, inserted_at, updated_at) VALUES ($1, 'd', now(), now())",
      [name]
    )
  end

  test "renames stored requirement rows and agents' held tasks, and back" do
    scope = full_scope_fixture()
    insert_requirement("requirements", "code_on_running_copy")
    insert_requirement("shadow_requirements", "code_on_running_copy")

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "agent", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/rename/agent")

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: copy.root,
        working_copy_id: copy.id
      })

    {:ok, agent} = TaskOwner.add_task(scope, agent, %{requirement_name: "code_on_running_copy"})

    # Already applied to this database; run it again inside the sandbox. The
    # migrator runs it from a task, so the connection is shared.
    Sandbox.mode(Repo, {:shared, self()})
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    module = migration()

    assert :ok = Ecto.Migrator.up(Repo, @version, module, log: false, migration_lock: false)

    assert names("requirements") == ["story_promoted"]
    assert names("shadow_requirements") == ["story_promoted"]

    {:ok, agent} = AgentsRepository.fetch_agent(scope, agent.id)
    assert [%{requirement_name: "story_promoted"}] = agent.tasks

    assert :ok = Ecto.Migrator.down(Repo, @version, module, log: false, migration_lock: false)
    assert names("requirements") == ["code_on_running_copy"]
  end
end
