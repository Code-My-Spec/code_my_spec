defmodule CodeMySpec.Repo.Migrations.AGraphRemembersTheShapeItsEdgesDescribe do
  @moduledoc """
  The topology the published edges were computed from.

  Story 1020. Requirements now carry their own input fingerprints, so a read
  recomputes the entities whose sources moved and keeps the rest. Edges were
  kept wholesale alongside them, which is where the saving actually is —
  measured, edges were 6489ms of a 10203ms compute, against 3714ms for every
  node in the project — and also where keeping them was unjustified.

  Edges are not computed from the same inputs as nodes. `cross_context_dependency_edges/2`
  reads `component.dependencies`, the component tree reads `parent_component_id`,
  and the config decides which definitions exist to connect at all. A spec file
  declaring a new dependency moves that component's files, so the component was
  correctly recomputed — and its new edge was silently dropped, because the
  stored edges were reused on the strength of the entity set being unchanged.
  Membership is not shape.

  `topology_fingerprint` is the shape: every input an edge is computed from,
  hashed. Edges are reused when it matches and recomputed when it does not,
  which is the difference between a graph that is cheap and a graph that is
  cheap and right.

  Nullable, and read as "no basis to reuse" — rows written before this say
  nothing about the shape they describe, so the first read after this migration
  recomputes edges once and records what they were computed from.
  """

  use Ecto.Migration

  def change do
    alter table(:requirement_graphs) do
      add :topology_fingerprint, :string
    end
  end
end
