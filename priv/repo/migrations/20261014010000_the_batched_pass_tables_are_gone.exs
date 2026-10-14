defmodule CodeMySpec.Repo.Migrations.TheBatchedPassTablesAreGone do
  @moduledoc """
  The tables only the batched graph pass used.

  `shadow_requirements` and `shadow_requirement_edges` held the pass's output as
  the oracle the event projection was compared against; `requirement_graphs`
  held its fingerprint cache. The event projection writes `requirements` and
  `requirement_edges`, and nothing reads these three. Their rows were derived,
  so there is nothing to keep; a rollback recreates nothing.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:shadow_requirement_edges)
    drop_if_exists table(:shadow_requirements)
    drop_if_exists table(:requirement_graphs)
  end

  def down do
    raise Ecto.MigrationError,
          "the batched pass's tables held derived rows and are not recreated"
  end
end
