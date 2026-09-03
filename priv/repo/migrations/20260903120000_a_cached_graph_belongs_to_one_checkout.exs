defmodule CodeMySpec.Repo.Migrations.ACachedGraphBelongsToOneCheckout do
  @moduledoc """
  The requirement graph cache was keyed by project, and the graph it caches is
  not a property of a project.

  `NodeRepository.upsert_all/2` already writes and deletes per working copy —
  its own comment says writing without saying whose view it is "is what let any
  checkout overwrite the project's whole graph". The cache that *gates* those
  writes kept the project grain, so one checkout publishing made another
  checkout's computation return `:unchanged`, and `persist_projection/5` wrote
  nothing for it.

  Observed: stories 989/990/991 had their spec files, with story ids, in the
  devops-q checkout, and `bdd_specs_exist` still read unsatisfied. The only rows
  for those stories belonged to the main checkout — correctly false there, since
  the files were uncommitted — and devops-q had no requirement rows at all, out
  of 10,017 in the table. Issue `5b538c8b`.
  """

  use Ecto.Migration

  def up do
    alter table(:requirement_graphs) do
      # Nullable, and that is a real value rather than an omission: the web UI
      # computes with no working copy, deliberately blending every checkout, and
      # `upsert_all/2` already gives that vantage point its own rows. It gets its
      # own cache row for the same reason.
      add :working_copy_id, references(:working_copies, type: :uuid, on_delete: :delete_all)
    end

    # NULLS NOT DISTINCT so the blended UI row collides with itself rather than
    # accumulating one per publish — matching `requirements`' own indexes, which
    # already spell every one of these the same way.
    drop unique_index(:requirement_graphs, [:project_id])

    create unique_index(:requirement_graphs, [:project_id, :working_copy_id],
             nulls_distinct: false
           )
  end

  def down do
    # The old index cannot be restored while two checkouts of one project each
    # hold a row, so the extra rows go first. The main checkout's is kept when
    # there is one, since that is the row the project-keyed cache effectively
    # served; otherwise the oldest, which is the one everything else points at.
    execute """
    DELETE FROM requirement_graphs g
    USING requirement_graphs keep
    WHERE g.project_id = keep.project_id
      AND g.id <> keep.id
      AND keep.id = (
        SELECT id FROM requirement_graphs inner_g
        WHERE inner_g.project_id = g.project_id
        ORDER BY inner_g.working_copy_id IS NOT NULL, inner_g.inserted_at
        LIMIT 1
      )
    """

    drop unique_index(:requirement_graphs, [:project_id, :working_copy_id],
           nulls_distinct: false
         )

    create unique_index(:requirement_graphs, [:project_id])

    alter table(:requirement_graphs) do
      remove :working_copy_id
    end
  end
end
