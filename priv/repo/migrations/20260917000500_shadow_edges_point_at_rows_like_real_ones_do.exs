defmodule CodeMySpec.Repo.Migrations.ShadowEdgesPointAtRowsLikeRealOnesDo do
  use Ecto.Migration

  @moduledoc """
  The two edge tables were different shapes, which is what stopped the swap.

  `requirement_edges` joins two row ids. `shadow_requirement_edges` stored the
  entity/name key on both ends, because the event path wrote edges before it
  knew what ids its nodes got. That was fine while the shadow was only ever
  compared, and it blocks the projections trading places: flipping the flag
  would have handed the event path the real nodes while leaving real edges
  pointing at rows nothing wrote any more.

  So the shadow learns the shape the real table already has. Each side keeps its
  own ids — an edge references rows in its own node table — and `diff/1`
  translates both back to keys before comparing, which is what `live_edge_keys/4`
  has always done.

  Nullable, because the existing rows have no ids to backfill and the next
  projection replaces them wholesale. No foreign keys, following the rest of
  this table: the shadow must never be able to refuse a write that the real
  projection would have accepted.
  """

  def change do
    alter table(:shadow_requirement_edges) do
      add :from_requirement_id, :bigint
      add :to_requirement_id, :bigint
    end

    create index(:shadow_requirement_edges, [:from_requirement_id])
    create index(:shadow_requirement_edges, [:to_requirement_id])
  end
end
