defmodule CodeMySpec.Repo.Migrations.TheShadowCarriesItsTopology do
  @moduledoc """
  Edges for the event-derived projection, so the diff can compare topology.

  `shadow_requirements` mirrored the live table's *verdicts* and nothing else,
  which made the comparison that earned the swap a comparison of half the graph.
  Prerequisites are edges, `get_next_requirement` answers "whose prerequisites
  are met", and a projection with no topology hands an agent an implementation
  before its spec exists.

  ## Keyed by node key, not by row id

  `requirement_edges` keys on `requirements(id)` at both ends. The shadow cannot
  borrow that: its rows have their own sequence, so the same integers mean
  different requirements in the two tables — an id-keyed shadow edge would not
  merely be missing, it would point somewhere wrong, and a diff comparing ids
  would be comparing noise.

  So an edge is stored as the pair of node keys it actually is —
  `{entity_type, entity_id, name}` at each end. That is the form the diff wants
  anyway, and it is the form `RequirementGraph` produces before
  `NodeRepository.replace_edges/3` resolves it to ids.

  `entity_id` is text because it is a uuid for a component or project and a
  bigint for a story; the live table sidesteps that by pointing at a row instead.

  ## No foreign keys, deliberately

  Same reason `20260916013000` took the entity FKs off `graph_invalidations`: a
  delete broadcasts *after* its row is gone, so an FK here turns a projection
  write into a raise inside an unrelated domain write.
  """
  use Ecto.Migration

  def change do
    create table(:shadow_requirement_edges) do
      add :project_id, :binary_id, null: false
      add :working_copy_id, :binary_id

      add :from_entity_type, :string, null: false
      add :from_entity_id, :string, null: false
      add :from_name, :string, null: false

      add :to_entity_type, :string, null: false
      add :to_entity_id, :string, null: false
      add :to_name, :string, null: false

      timestamps(updated_at: false)
    end

    # The vantage is nullable and the null means something — the unscoped row is
    # the project-wide answer — so the index has to treat two nulls as equal or
    # it keeps one duplicate per write.
    create unique_index(
             :shadow_requirement_edges,
             [
               :project_id,
               :working_copy_id,
               :from_entity_type,
               :from_entity_id,
               :from_name,
               :to_entity_type,
               :to_entity_id,
               :to_name
             ],
             name: :shadow_requirement_edges_unique,
             nulls_distinct: false
           )

    # What the diff reads: one vantage's whole topology.
    create index(:shadow_requirement_edges, [:project_id, :working_copy_id])
  end
end
