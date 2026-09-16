defmodule CodeMySpec.Repo.Migrations.AWriterNamesWhatItInvalidated do
  use Ecto.Migration

  # The event-based half of staleness, running beside the fingerprints rather
  # than instead of them, until a diff says it is the better of the two.
  #
  # ## Why the marks are rows
  #
  # Staleness today is *derived*: `requirements.inputs_fingerprint` records what
  # a row was computed from, the pass hashes the live context, and the two are
  # compared. That is why it survives a restart — nothing is remembered, it is
  # worked out again from scratch every pass.
  #
  # Event staleness is *accumulated*: a writer says "component X moved", a
  # consumer recomputes X and clears the mark. Which means the mark has to
  # outlive the process that made it. An in-memory dirty set loses everything on
  # deploy, and the loss reads as "nothing is stale" — the silent direction,
  # where a row keeps serving an answer nothing will ever revisit. A missed
  # recompute costs an agent a session; an extra one costs a recompute.
  #
  # This is an outbox, not a queue to be drained in batches. A mark is consumed
  # on its own, as it arrives; rows only accumulate when the consumer is behind
  # or was down. The debounce that `GraphWatcher` needs — because a fingerprint
  # pass is whole-project and coalescing a burst is the only thing that makes it
  # affordable — is exactly what an event consumer must not inherit. Per-entity
  # work is the reason events are worth having, and a consumer that batched
  # would be a fingerprint pass with extra steps.
  #
  # Both entity columns null means project-wide: a writer that has not been
  # narrowed to the entities it actually moved. Not a permanent shape — a
  # measurement. `working_copies` moves every story's fingerprint today and is
  # the most expensive input on this project, so counting the passes a
  # project-wide mark blows out is how we learn which writers to narrow first.
  #
  # ## Why the shadow is a whole table
  #
  # `shadow_requirements` mirrors `requirements` column for column so
  # `{"shadow_requirements", Requirements.Node}` reuses the schema, the
  # changeset and the upsert conflict targets unchanged. The diff then compares
  # two projections built by the same writer through two different staleness
  # decisions — so a difference is the decision, which is the only variable
  # under test.
  #
  # A discriminator column on `requirements` would have been a smaller
  # migration and a smaller swap. It also puts the experiment inside the table
  # every read depends on, and the live projection has to keep working while
  # this is wrong. Separate table, zero blast radius, and the swap is which
  # source `Projection.load/2` names.
  #
  # Edges are deliberately absent. They are computed from `Freshness.topology/2`
  # — the component tree, dependencies, story attachment and the config — which
  # is not a domain fingerprint and is not what this replaces.
  def change do
    create table(:graph_invalidations) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all)
      add :story_id, references(:stories, on_delete: :delete_all)

      # Who said so. The same string `GraphInputs.announce/2` already writes to
      # the log, kept here so a diff can name the writer that owes an event
      # rather than only the entity that went stale without one.
      add :source, :string, null: false

      # Ties a mark to the burst it came from, so a mark that outlives its
      # consumer can be traced back to the announcement that made it.
      add :observation_id, :string

      timestamps(updated_at: false)
    end

    # Marks are read for one project and deleted by id. Nothing queries by
    # entity, so this is the only index the consumer needs.
    create index(:graph_invalidations, [:project_id])

    # Column for column with `requirements`, defaults included. The defaults are
    # load-bearing rather than decorative: `Node.changeset/2` does not cast
    # `artifact_type`, `scope` or `depends_on`, so an insert that reaches this
    # table relies on them exactly as it relies on them in the live one. A
    # mirror that differed here would make the diff a report on this migration.
    create table(:shadow_requirements) do
      add :name, :string, null: false
      add :description, :text, null: false
      add :checker_module, :string
      add :satisfied_by, :string
      add :satisfied, :boolean, null: false, default: false
      add :checked_at, :naive_datetime
      add :details, :map, null: false, default: %{}
      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all)
      add :artifact_type, :string, null: false, default: "specification"
      add :score, :float
      add :story_id, :bigint
      add :project_id, :binary_id
      add :scope, :string, default: "local"
      add :depends_on, :text, default: "[]"
      add :validation_type, :string
      add :execution_type, :string

      add :working_copy_id,
          references(:working_copies, type: :binary_id, on_delete: :delete_all)

      add :inputs_fingerprint, :string
      add :owner_component_type, :string
      add :node_scope, :string

      timestamps()
    end

    # The three partial uniques are the conflict targets `persist_projection/5`
    # upserts against, so the mirror needs them by the same shape or the same
    # writer behaves differently against it.
    create unique_index(:shadow_requirements, [:component_id, :name, :working_copy_id],
             where: "component_id IS NOT NULL",
             nulls_distinct: false,
             name: :shadow_requirements_component_id_name_index
           )

    create unique_index(:shadow_requirements, [:story_id, :name, :working_copy_id],
             where: "story_id IS NOT NULL",
             nulls_distinct: false,
             name: :shadow_requirements_story_id_name_index
           )

    create unique_index(:shadow_requirements, [:project_id, :name, :working_copy_id],
             where: "project_id IS NOT NULL",
             nulls_distinct: false,
             name: :shadow_requirements_project_id_name_index
           )

    create index(:shadow_requirements, [:working_copy_id])
  end
end
