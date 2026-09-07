defmodule CodeMySpec.Repo.Migrations.TheRequirementGraphIsRowsNotAPayload do
  @moduledoc """
  The second copy of the graph goes.

  `requirement_graphs.payload` held the whole computed graph as a compressed
  Erlang term, from before `requirements` and `requirement_edges` existed. Once
  they did, the payload was a duplicate that could disagree with them, kept
  deliberately while the read model proved itself: `RequirementGraph` served the
  rows, compared them against the payload on every publish, and fell back to the
  payload only when a project had no rows at all.

  `GraphCache`'s moduledoc named three conditions for removing it and all three
  are met. `[Requirements] the projection does not round-trip` has never
  appeared — 828 graph computations across four rotated logs, and that check
  runs on every publish, which is every genuine change. Neither has
  `projection is empty for a payload`. And `fetch/2`'s graph had exactly one
  reader, the comparison itself.

  What the payload really covered is kept, in `node_count`: rows that are empty
  where the publish counted nodes were never written, and that is a cache miss —
  recompute — rather than an empty graph served as current. An empty graph tells
  an agent it has no work.

  No backfill and nothing to preserve. Every row's fingerprint still describes
  the rows it was published with, and a fingerprint that no longer matches is
  already a miss.
  """

  use Ecto.Migration

  def up do
    alter table(:requirement_graphs) do
      remove :payload
    end
  end

  # Restoring the column restores a nullable one, which is the honest inverse:
  # the graphs it held are gone, and a row whose payload is null reads as a
  # graph whose rows were never written. Rolling back means recomputing, which
  # the fingerprint check already does on its own.
  def down do
    alter table(:requirement_graphs) do
      add :payload, :binary
    end
  end
end
