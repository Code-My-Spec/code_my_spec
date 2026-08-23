defmodule CodeMySpec.Repo.Migrations.AgentsNameTheirLane do
  @moduledoc """
  Which lane on the working copy this agent is.

  A working copy runs one or more agents, and until now the row could not say
  which one it was: `record_reported/2` found the copy's agent with
  `Enum.find(&(&1.working_copy == root))`, so a second lane on the same copy
  overwrote the first instead of joining it. The list claimed one agent per
  checkout because the schema could not hold two.

  `role` is what the harness already calls a lane — `CodeMySpecLocalWeb.HarnessChannel`
  joins `harness:session:<external_id>` with a role and tracks Presence under
  it, so the name is taken from the thing being described rather than invented
  here.

  Backfilled to "main" rather than left null: every existing row is the one
  lane its copy was reporting, and a null would make "which lane" unanswerable
  for rows that do have an answer. No default on the column — that lives on the
  schema, where the code that writes rows can see it.
  """

  use Ecto.Migration

  def up do
    alter table(:agents) do
      add :role, :string
    end

    execute("UPDATE agents SET role = 'main' WHERE role IS NULL")

    alter table(:agents) do
      modify :role, :string, null: false
    end

    # The reconcile's lookup, which is now per lane rather than per copy.
    create index(:agents, [:project_id, :working_copy, :role])
  end

  def down do
    drop index(:agents, [:project_id, :working_copy, :role])

    alter table(:agents) do
      remove :role
    end
  end
end
