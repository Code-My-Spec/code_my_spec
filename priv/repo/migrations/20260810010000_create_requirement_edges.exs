defmodule CodeMySpec.Repo.Migrations.CreateRequirementEdges do
  use Ecto.Migration

  # The graph's edges, as rows.
  #
  # They lived in `requirement_graphs.payload`, a `bytea` holding the whole
  # graph addressed by one fingerprint hash. Nothing in it could be queried,
  # joined or partially invalidated: "which requirements does this file affect"
  # had no answer, and a single changed input meant throwing the payload away
  # and recomputing everything.
  #
  # ## Two foreign keys, no entity keys
  #
  # An edge connects two requirement *nodes*, and `requirements` already
  # resolves what a node belongs to — `component_id`, `story_id` and
  # `project_id` are separate typed columns there. So an edge needs neither an
  # entity type nor an entity id; it needs two node ids.
  #
  # The alternative was carrying `{entity_type, entity_id, name}` on both ends,
  # which `Topology.node_key/1` uses in memory. It would have meant six columns,
  # and `entity_id` as a string because it is a UUID for components and projects
  # and an integer for stories — so no real foreign key, and no referential
  # integrity at all.
  #
  # `on_delete: :delete_all` is what makes this safe to derive: deleting a
  # component takes its requirements, and its requirements take their edges. No
  # sweep, and no edge can outlive either end.
  def change do
    create table(:requirement_edges) do
      add :from_requirement_id, references(:requirements, on_delete: :delete_all), null: false
      add :to_requirement_id, references(:requirements, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    # An edge is the pair. Recomputation upserts against this rather than
    # deleting the project's edges and reinserting, so a graph that did not
    # change does not churn the table.
    create unique_index(:requirement_edges, [:from_requirement_id, :to_requirement_id])

    # "What depends on this requirement" is the question the UI asks walking
    # down, and `from` alone is indexed by the unique index above.
    create index(:requirement_edges, [:to_requirement_id])
  end
end
