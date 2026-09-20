defmodule CodeMySpec.Repo.Migrations.TheShadowEdgesAreTheSameFourColumns do
  use Ecto.Migration

  @moduledoc """
  The follow-through `EitherWriterCanOwnTheShadowEdges` named.

  That migration made the entity/name key optional and said the columns "go
  when the comparison reads ids on both sides". `edge_identity/1` reads ids on
  both sides as of `50d4d8bb4`, so they go here.

  ## Why they existed and why they do not

  The event path wrote an edge before it knew what row ids its nodes had got,
  so the key was the only stable thing it could store. That stopped being true
  when `write/3` learned to upsert: a node keeps its id now, `write_edges/2`
  resolves both endpoints against the nodes it just wrote, and the key columns
  became a second copy of what the two ids already say. They were read in
  exactly three places, all of them `write_edges/2` talking to itself.

  `project_id` and `working_copy_id` go with them. They were a denormalisation
  that made the vantage-scoped delete a cheap indexed filter, and the real
  table has never had them — `edge_keys/6` already scopes by node id on both
  sides, with a comment saying it does it that way because only one of the two
  tables has a project column. `write_edges/2` has the vantage's node ids in
  hand before it writes, so scoping through them costs no query at all.

  What is left is `requirement_edges`: two row ids, a primary key and a
  timestamp. The two tables are now the same shape, which is what makes
  `graph_event_is_source` a switch rather than a trap — flipping it today
  handed `write_edges/2` a table with eight columns it does not have.

  ## The foreign keys are the point, not tidiness

  `requirement_edges` cascades on delete and this table did not, which is how
  it accumulated 127,254 edges pointing at nodes that no longer existed —
  invisible until the diff started reporting edges, and unrepairable because
  the only writer that could have fixed them matched on the keys and believed
  they were correct. With the cascade, a deleted node takes its edges with it:
  the failure becomes impossible rather than merely fixed.

  Orphans are deleted first because the constraint refuses them. There are none
  on dev — the seed rewrote every edge once ids became part of their identity —
  but a test partition that has not seeded since will have plenty.
  """

  def change do
    execute(
      """
      DELETE FROM shadow_requirement_edges e
       WHERE e.from_requirement_id IS NULL
          OR e.to_requirement_id IS NULL
          OR NOT EXISTS (SELECT 1 FROM shadow_requirements n WHERE n.id = e.from_requirement_id)
          OR NOT EXISTS (SELECT 1 FROM shadow_requirements n WHERE n.id = e.to_requirement_id)
      """,
      ""
    )

    drop_if_exists(
      unique_index(
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
        name: :shadow_requirement_edges_unique
      )
    )

    drop_if_exists(index(:shadow_requirement_edges, [:from_requirement_id]))

    alter table(:shadow_requirement_edges) do
      remove :from_entity_type, :string
      remove :from_entity_id, :string
      remove :from_name, :string
      remove :to_entity_type, :string
      remove :to_entity_id, :string
      remove :to_name, :string
      remove :project_id, :uuid
      remove :working_copy_id, :uuid
    end

    alter table(:shadow_requirement_edges) do
      modify :from_requirement_id,
             references(:shadow_requirements, on_delete: :delete_all),
             null: false,
             from: :bigint

      modify :to_requirement_id,
             references(:shadow_requirements, on_delete: :delete_all),
             null: false,
             from: :bigint
    end

    create unique_index(:shadow_requirement_edges, [:from_requirement_id, :to_requirement_id])
  end
end
