defmodule CodeMySpec.Repo.Migrations.AProjectDrawsItsEdgesOnce do
  @moduledoc """
  One edge set per project, not one per checkout.

  An edge is a function of records alone, so every checkout shares it; a
  checkout's edges are the ones whose two ends are rows there. `requirement_edges`
  pointed at per-checkout row ids, so it stored the same edges once per checkout.

  `edges` is the topology as generated, unreduced; `display_edges` its
  transitive reduction, for views that draw it. Both are erlang terms keyed by
  `{entity_type, entity_id, name}`. `topology` is the hash they were drawn
  from (`Freshness.topology/2`).

  Created empty: each projector draws its project's row on its first drain, and
  a project without one reads as unprojected. `requirement_edges` stops being
  read or written here and is dropped in a later migration.
  """

  use Ecto.Migration

  def change do
    create table(:requirement_topologies, primary_key: false) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :topology, :string, null: false
      add :edges, :binary, null: false
      add :display_edges, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
