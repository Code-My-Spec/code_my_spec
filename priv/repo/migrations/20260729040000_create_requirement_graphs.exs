defmodule CodeMySpec.Repo.Migrations.CreateRequirementGraphs do
  use Ecto.Migration

  # The requirement graph is derived state — a pure function of Files,
  # Problems, components, stories, analysis freshness and config. Computing it
  # takes ~170ms on a 1000-file project, which is affordable for whoever holds
  # those inputs and not affordable as a precondition for rendering a page.
  #
  # Caching it separates producing from reading. A sprite, which has the inputs
  # and is already isolated per project, computes and writes. The web UI reads,
  # and keeps working when no sprite is running — it shows the last known state
  # rather than nothing.
  #
  # One row per project: the graph is whole-project by construction (it has
  # project-level fan-in nodes), so there is nothing partial to store.
  def change do
    create table(:requirement_graphs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      # Hash of every input the graph was computed from. A reader compares it
      # against a freshly computed fingerprint and recomputes on mismatch, so a
      # stale row is never served — it is only ever a miss.
      add :fingerprint, :string, null: false

      # :erlang.term_to_binary of {nodes, edges}. Opaque on purpose: nodes are
      # Requirement structs and edge endpoints are tuples, neither of which
      # survives JSON without a hand-written codec whose bugs would surface as
      # wrong agent instructions. The payload is a cache — reconstructible from
      # the rows it summarizes — so opacity costs little. A JSON projection can
      # be added if a non-Elixir reader ever needs one.
      add :payload, :binary, null: false

      add :node_count, :integer, null: false
      add :edge_count, :integer, null: false

      # Which process computed it. Not used for correctness today; it is the
      # hook for answering "which checkout is this status from?" once a project
      # can have more than one producer.
      add :computed_by, :string
      add :computed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:requirement_graphs, [:project_id])
  end
end
