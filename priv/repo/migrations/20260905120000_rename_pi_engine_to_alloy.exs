defmodule CodeMySpec.Repo.Migrations.RenamePiEngineToAlloy do
  use Ecto.Migration

  # `agents.engine` stored `"pi"` for every agent on this deployment — the
  # schema's enum value from before the product backed out of running that
  # agent at all. The atom changed everywhere it is matched on
  # (`CodeMySpec.Agents.Agent`, `CodeMySpec.Agents`, the MCP `start_agent`
  # tool, `HarnessChannel`'s wire default, `WorkingCopyLive.Liveness`), and
  # the column has to follow or every existing row casts to nothing: the
  # `Ecto.Enum` no longer recognizes `"pi"` as a value at all.
  #
  # A plain `UPDATE`, not a schema change — `engine` was always a string
  # column under `Ecto.Enum`, never a Postgres enum type, so there is no type
  # to alter.
  def up do
    execute("UPDATE agents SET engine = 'alloy' WHERE engine = 'pi'")
  end

  def down do
    execute("UPDATE agents SET engine = 'pi' WHERE engine = 'alloy'")
  end
end
